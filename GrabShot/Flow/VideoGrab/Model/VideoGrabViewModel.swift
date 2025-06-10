//
//  VideoGrabViewModel.swift
//  GrabShot
//
//  Created by Denis Dmitriev on 25.12.2023.
//

import SwiftUI
import Combine
import FirebaseAnalytics
import FirebaseCrashlytics

class VideoGrabViewModel: ObservableObject {
    @Published var grabState: VideoGrabState = .ready
    @Published var error: GrabError?
    @Published var hasError: Bool = false
    @Published var currentTimecode: Duration = .zero
    @Published var isProgress: Bool = false
    @AppStorage(DefaultsKeys.stripViewMode) var stripMode: StripMode = .liner
    var grabber: Grabber?
    var stripImageCreator: StripImageCreator?
    var stripColorManager: StripColorManager?
    weak var coordinator: GrabCoordinator?
    
    @AppStorage(DefaultsKeys.exportGrabbingImageFormat)
    private var exportGrabbingImageFormat: FileService.Format = .jpeg
    
    // MARK: Cut Video
    func cut(video: Video, from: Duration, to: Duration) {
        guard video.exportDirectory != nil else {
            coordinator?.presentAlert(error: .exportDirectoryFailure(title: video.title))
            coordinator?.showRequirements = true
            return
        }
        progress(is: true)
        FFmpegVideoService.cut(in: video, from: from, to: to, callBackProgress: { progress in
            DispatchQueue.main.async {
                // Update progress
                if video.progress.total != progress.total {
                    video.progress.total = progress.total
                }
                video.progress.current = min(progress.value, progress.total)
                
                // Update current timecode
                let seconds = video.rangeTimecode.lowerBound.seconds + (progress.percent * video.rangeTimecode.duration.seconds)
                self.currentTimecode = .seconds(seconds)
            }
        }) { [weak self] result in
            switch result {
            case .success(let urlVideo):
                print("success", urlVideo)
                Analytics.logEvent(
                    AnalyticsEvent.cutVideoFinish.key,
                    parameters: [
                        "cut_range": "\(from.seconds - to.seconds) / \(video.duration)"
                    ]
                )
            case .failure(let failure):
                if let failure = failure as? LocalizedError {
                    self?.presentError(failure)
                }
            }
            self?.progress(is: false)
        }
    }
    
    // MARK: Grabbing Video
    func grabbingRouter(for video: Video, period: Double) {
        guard video.exportDirectory != nil else {
            coordinator?.presentAlert(error: .exportDirectoryFailure(title: video.title))
            coordinator?.showRequirements = true
            return
        }
        switch grabState {
        case .ready, .complete, .canceled:
            startGrab(video: video, period: period)
        case .pause:
            resumeGrab()
        case .grabbing:
            pauseGrab()
        case .calculating:
            return
        }
    }
    
    private func didFinishGrabbing(for video: Video) {
        defer {
            Analytics.logEvent(
                AnalyticsEvent.grabFinish.key,
                parameters: [
                    "grab_period": UserDefaultsService.default.period,
                    "grab_count": video.progress.current
                ]
            )
        }
        defer {
            if UserDefaultsService.default.openDirToggle, let exportDirectory = video.exportDirectory {
                FileService.openDirectory(by: exportDirectory)
            }
        }
        createSumaryImage(for: video)
        createStripImage(for: video)
    }
    
    func startGrab(video: Video, period: Double) {
        progress(is: true)
        // Prepare
        video.reset()
        video.lastRangeTimecode = switch video.range {
        case .full:
            video.timelineRange
        case .excerpt:
            video.rangeTimecode
        }
        grabber = Grabber(video: video, period: period, format: exportGrabbingImageFormat, delegate: self)
        createStripManager()
        
        // Start
        grabber?.start()
    }
    
    func pauseGrab() {
        progress(is: false)
        grabber?.pause()
    }
    
    func resumeGrab() {
        progress(is: true)
        grabber?.resume()
    }
    
    func cancelGrab() {
        progress(is: false)
        grabber?.cancel()
    }
    
    private func didUpdate(video: Video, progress: Int, timecode: Duration, imageURL: URL) async {
        // Add colors to video
        await stripColorManager?.appendAverageColors(for: video, from: imageURL)
        
        DispatchQueue.main.async {
            // Update last range
            if let lastRangeTimecode = video.lastRangeTimecode {
                video.lastRangeTimecode = .init(uncheckedBounds: (lower: lastRangeTimecode.lowerBound, upper: timecode))
            }
            
            // Update progress
            video.progress.current = min(progress, video.progress.total)
            
            // Update current timcode
            self.currentTimecode = timecode
            
            // Check for complete
            if video.progress.total == video.progress.current {
                self.didFinishGrabbing(for: video)
                self.progress(is: false)
            }
        }
    }
    
    // MARK: StripManager
    private func createStripManager() {
        stripColorManager = StripColorManager(stripColorCount:  UserDefaultsService.default.stripCount)
    }
    
    // MARK: - StripCreator
    private func createStripImageCreator() {
        stripImageCreator = GrabStripCreator()
    }
    
    func createStripImage(for video: Video) {
        guard !video.grabColors.isEmpty,
              let url = video.exportDirectory
        else { return }
        
        let name = video.grabName + ".Strip"
        let exportURL = url.appendingPathComponent(name)
        
        let width = UserDefaultsService.default.stripSize.width
        let height = UserDefaultsService.default.stripSize.height
        let size = CGSize(width: width, height: height)
        
        createStripImageCreator()
        
        do {
            try stripImageCreator?.create(to: exportURL, with: video.grabColors, size: size, stripMode: stripMode, format: exportGrabbingImageFormat)
            Analytics.logEvent(
                AnalyticsEvent.grabFinish.key,
                parameters: [
                    "strip_size": size,
                    "count_colors": video.grabColors.count,
                    "strip_mode": stripMode.name,
                    "image_format": exportGrabbingImageFormat.rawValue
                ]
            )
        } catch let error as LocalizedError {
            self.presentError(error)
            Crashlytics.crashlytics().record(error: error, userInfo: ["function": #function, "object": type(of: self)])
        } catch {
            print(error.localizedDescription)
        }
    }
    
    func createSumaryImage(for video: Video) {
        let urls = video.images
        let title = video.title + ".Grid"
        let duration = video.duration
        let size = video.size
        
        let gridHeader: CGFloat = 100
        let gridCollunmCount: Int = 3
        let gridbodyMargin: CGFloat = 10
        let gridFooter: CGFloat = 50
        
        // ดึงสีสำหรับ gradient
        let colors = video.grabColors
        
        // โหลดรูปภาพจาก URLs
        let images = urls.compactMap { NSImage(contentsOf: $0) }
        guard !images.isEmpty else {
            print("ไม่พบรูปภาพใน video.images")
            return
        }
        
        // แก้ไข: ใช้ aspect ratio จาก video.size สำหรับขนาดรูปภาพใน grid
        let videoSize = size ?? CGSize(width: 1024, height: 1024) // ค่า default ถ้า size เป็น nil
        let aspectRatio = videoSize.height / videoSize.width
        let imageWidth: CGFloat = 200 // ความกว้างคงที่ (ปรับได้)
        let imageHeight: CGFloat = imageWidth * aspectRatio // ความสูงตาม ratio
        
        // คำนวณขนาดของ grid
        let rows = Int(ceil(Double(images.count) / Double(gridCollunmCount)))
        let totalWidth = CGFloat(gridCollunmCount) * (imageWidth + gridbodyMargin) + gridbodyMargin
        let totalHeight = CGFloat(rows) * (imageHeight + gridbodyMargin) + gridHeader + gridFooter + gridbodyMargin
        
        // สร้าง NSImage สำหรับ grid
        let outputImage = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
        
        outputImage.lockFocus()
        
        // วาดพื้นหลัง gradient
        /*
        let color1: NSColor = NSColor(colors.randomElement() ?? .black)
        let color2: NSColor = NSColor(colors.randomElement() ?? .black)
        let color3: NSColor = NSColor(colors.randomElement() ?? .black)
        let gradient = NSGradient(colors: [color1, color2, color3],
                                  atLocations: [0.0, 0.5, 1.0],
                                  colorSpace: .deviceRGB)
        gradient?.draw(in: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight), angle: 45)
        */
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight)).fill()
        
        // วาดส่วนหัว (header)
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        let durationStr = String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        
        let widthText = String(format: "%.0f", videoSize.width)
        let heightText = String(format: "%.0f", videoSize.height)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.black
        ]
        let lineSpacing: CGFloat = 10
        let columnWidth = (totalWidth - 3 * gridbodyMargin) / 2 // แบ่งคอลัมน์ซ้าย-ขวา
        var titleCurrentY = totalHeight - gridHeader + 10
        
        guard let videoFormat = video.metadata?.format,
        let sizeStr = videoFormat.value(for: .size) else {
            return
        }
        let textArray = [
            "Resolution: \(widthText) x \(heightText)",
            "Duration: \(durationStr)",
            "Fire Size: \(sizeStr)",
            "Fire Name: \(video.title)"
        ]
        
        for text in textArray {
            let textRect = NSRect(x: gridbodyMargin, y: titleCurrentY, width: totalWidth, height: 20)
            
            titleCurrentY += 10 + lineSpacing
            text.draw(in: textRect, withAttributes: attributes)
        }
        /*
        let headerLines: [String : Any] = [
            "left" : "Title: \(video.title)",
            "right": ["Duration: \(durationStr)", "Resolution: \(widthText)x\(heightText)"]
        ]
        
        // คอลัมน์ซ้าย: Title
        if let leftText = headerLines["left"] as? String {
            let leftRect = NSRect(x: gridbodyMargin, y: titleCurrentY, width: columnWidth, height: gridHeader / 2)
            leftText.draw(in: leftRect, withAttributes: attributes)
        }
        
        if let headerRight = headerLines["right"] as? [String] {
            for (index, rightLine) in headerRight.enumerated() {
                let reHeight: CGFloat = gridHeader / 4
                let rightRect = NSRect(x: gridbodyMargin + (totalWidth / 2),y: titleCurrentY,width: columnWidth,height: reHeight)
                rightLine.draw(in: rightRect, withAttributes: attributes)
                titleCurrentY = titleCurrentY + lineSpacing + reHeight;
                
            }
        }
        */
        // วาดรูปภาพใน grid
        let attImg: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.5)
        ]
        for (index, image) in images.enumerated() {
            let row = index / gridCollunmCount
            let col = index % gridCollunmCount
            let x = gridbodyMargin + CGFloat(col) * (imageWidth + gridbodyMargin)
            let y = gridbodyMargin + CGFloat(rows - 1 - row) * (imageHeight + gridbodyMargin) + gridFooter
            
            let scaledImage = scaleImage(image, to: NSSize(width: imageWidth, height: imageHeight))
            scaledImage.draw(in: NSRect(x: x, y: y, width: imageWidth, height: imageHeight))
            
            var filename = video.images[index].deletingPathExtension().lastPathComponent
            filename = String(filename.dropFirst(video.title.count + 1))
            
            
            // 2. แปลงจาก 01.45.00.00 → 01:45:00
            let parts = filename.components(separatedBy: ".")
            if parts.count >= 3 {
                let timeParts = parts.prefix(3) // [01, 45, 00]
                let timeString = timeParts.joined(separator: ":")
                print("Result: \(timeString)") // ✅ "01:45:00"
                let currentTimeStr = NSRect(x: x, y: y, width: imageWidth, height: 20)
                timeString.draw(in: currentTimeStr, withAttributes: attImg)
            } else {
                print("Invalid format")
            }
            
        }
        
        /*
        let footerText = "Footer: \(title)"
        let footerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.white
        ]
        let footerRect = NSRect(x: gridbodyMargin, y: 10, width: totalWidth - 2 * gridbodyMargin, height: gridFooter - 20)
        footerText.draw(in: footerRect, withAttributes: footerAttributes)
        */
        outputImage.unlockFocus()
        
        // บันทึกภาพไปยังตำแหน่งเดียวกับ video.images[0]
        guard let firstImageURL = urls.first,
              let tiffData = outputImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            print("ไม่สามารถบันทึกภาพได้")
            return
        }
        
        let saveURL = firstImageURL.deletingLastPathComponent().appendingPathComponent("\(title).jpeg")
        do {
            try pngData.write(to: saveURL)
            print("บันทึกภาพสำเร็จที่: \(saveURL.path)")
        } catch {
            print("ข้อผิดพลาดในการบันทึก: \(error)")
        }
    }

    // ฟังก์ชันช่วยปรับขนาดภาพ
    func scaleImage(_ image: NSImage, to size: NSSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

extension VideoGrabViewModel: GrabDelegate {
    func started(video: Video, progress: Int, total: Int) {
        DispatchQueue.main.async {
            video.progress.total = total
            video.progress.current = progress
            self.grabState = .grabbing
        }
    }
    
    func didPause() {
        DispatchQueue.main.async {
            self.grabState = .pause
        }
    }
    
    func didResume() {
        DispatchQueue.main.async {
            self.grabState = .grabbing
        }
    }
    
    func didUpdate(video: Video, progress: Int, timecode: Duration, imageURL: URL) {
        Task {
            await didUpdate(video: video, progress: progress, timecode: timecode, imageURL: imageURL)
        }
    }
    
    func completed(video: Video, progress: Int) {
        DispatchQueue.main.async {
            self.grabState = .complete(shots: progress)
        }
        grabber = nil
    }
    
    func canceled() {
        DispatchQueue.main.async {
            self.grabState = .canceled
        }
        stripColorManager = nil
        grabber = nil
    }
    
    func presentError(_ error: LocalizedError) {
        DispatchQueue.main.async {
            self.error = GrabError.map(errorDescription: error.localizedDescription, failureReason: error.failureReason)
            self.hasError = true
        }
    }
    
    func progress(is progress: Bool) {
        DispatchQueue.main.async {
            self.isProgress = progress
        }
    }
}

extension VideoGrabViewModel {
    static func build(store: VideoStore, score: ScoreController, coordinator: GrabCoordinator? = nil) -> VideoGrabViewModel {
        let viewModel = VideoGrabViewModel()
        viewModel.coordinator = coordinator
        return viewModel
    }
}
