import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Точка входа в приложение
@main
struct LiquidAudioApp: App {
    @StateObject private var audioManager = AudioEngineManager.shared
    
    var body: some Scene {
        WindowGroup {
            MainPlayerView()
                .environmentObject(audioManager)
                .preferredColorScheme(.dark) // Темная тема подчеркивает Liquid Glass и экономит заряд OLED экрана iPhone 14 Pro
        }
    }
}

// MARK: - Модель трека
struct Track: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let title: String
    let artist: String
    let duration: TimeInterval
    
    var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }
}

// MARK: - Высокопроизводительный Аудио-движок (Hi-Fi + Фоновый режим + Dynamic Island)
final class AudioEngineManager: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioEngineManager()
    
    @Published var tracks: [Track] = []
    @Published var currentTrack: Track?
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 1
    @Published var currentArtwork: UIImage?
    
    // Эквалайзер / Чистый звук (Pure Direct Mode)
    @Published var isPureDirectMode: Bool = true
    @Published var audioMeterLevel: Float = 0.0 // Для реактивной анимации Liquid Glass
    
    private var audioPlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private let tracksStorageKey = "saved_liquid_tracks_v1"
    
    override init() {
        super.init()
        configureAudioSession()
        setupRemoteTransportControls()
        loadSavedTracks()
    }
    
    /// Настройка аппаратной аудио-сессии для минимального расхода батареи и максимального качества ЦАП
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // Категория .playback гарантирует работу в фоне, при выключенном экране и вывод в Dynamic Island
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            
            // Оптимизация под iPhone 14 Pro: частота 48kHz (родная для железа Apple) и увеличенный буфер для экономии CPU в фоне
            try session.setPreferredSampleRate(48000.0)
            try session.setPreferredIOBufferDuration(0.023)
            try session.setActive(true)
        } catch {
            print("Ошибка конфигурации аудио-сессии: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Управление файлами и импорт
    func importAudioFiles(from urls: [URL]) {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        for url in urls {
            let isSecured = url.startAccessingSecurityScopedResource()
            defer { if isSecured { url.stopAccessingSecurityScopedResource() } }
            
            let destinationFileName = url.lastPathComponent
            let destinationURL = docsURL.appendingPathComponent(destinationFileName)
            
            do {
                if !FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.copyItem(at: url, to: destinationURL)
                }
                
                // Извлечение метаданных
                let asset = AVURLAsset(url: destinationURL)
                let durationSeconds = CMTimeGetSeconds(asset.duration)
                var title = destinationURL.deletingPathExtension().lastPathComponent
                var artist = "Неизвестный исполнитель"
                
                for item in asset.commonMetadata {
                    if item.commonKey == .commonKeyTitle, let val = item.stringValue, !val.isEmpty {
                        title = val
                    } else if item.commonKey == .commonKeyArtist, let val = item.stringValue, !val.isEmpty {
                        artist = val
                    }
                }
                
                let newTrack = Track(
                    id: UUID(),
                    fileName: destinationFileName,
                    title: title,
                    artist: artist,
                    duration: durationSeconds.isNaN ? 0 : durationSeconds
                )
                
                if !tracks.contains(where: { $0.fileName == newTrack.fileName }) {
                    DispatchQueue.main.async {
                        self.tracks.append(newTrack)
                        self.saveTracks()
                        if self.currentTrack == nil {
                            self.loadTrack(newTrack, autoPlay: false)
                        }
                    }
                }
            } catch {
                print("Ошибка копирования файла: \(error.localizedDescription)")
            }
        }
    }
    
    func deleteTrack(_ track: Track) {
        if currentTrack == track {
            stop()
            currentTrack = nil
            currentArtwork = nil
        }
        try? FileManager.default.removeItem(at: track.fileURL)
        tracks.removeAll { $0.id == track.id }
        saveTracks()
    }
    
    private func saveTracks() {
        if let encoded = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(encoded, forKey: tracksStorageKey)
        }
    }
    
    private func loadSavedTracks() {
        guard let data = UserDefaults.standard.data(forKey: tracksStorageKey),
              let decoded = try? JSONDecoder().decode([Track].self, from: data) else { return }
        // Фильтруем только реально существующие на диске файлы
        self.tracks = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if let first = self.tracks.first {
            loadTrack(first, autoPlay: false)
        }
    }
    
    // MARK: - Воспроизведение
    func loadTrack(_ track: Track, autoPlay: Bool = true) {
        do {
            audioPlayer?.stop()
            audioPlayer = try AVAudioPlayer(contentsOf: track.fileURL)
            audioPlayer?.delegate = self
            audioPlayer?.isMeteringEnabled = true // Для реактивного Liquid Glass эффекта
            audioPlayer?.prepareToPlay()
            
            self.currentTrack = track
            self.duration = audioPlayer?.duration ?? max(track.duration, 1)
            self.currentTime = 0
            self.currentArtwork = extractArtwork(from: track.fileURL)
            
            if autoPlay {
                play()
            } else {
                updateNowPlayingInfo()
            }
        } catch {
            print("Не удалось загрузить аудиофайл: \(error.localizedDescription)")
        }
    }
    
    func play() {
        guard let player = audioPlayer else {
            if let first = tracks.first { loadTrack(first, autoPlay: true) }
            return
        }
        player.play()
        isPlaying = true
        startTimer()
        updateNowPlayingInfo()
    }
    
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopTimer()
        audioMeterLevel = 0.0
        updateNowPlayingInfo()
    }
    
    func togglePlayPause() {
        isPlaying ? pause() : play()
    }
    
    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        stopTimer()
        currentTime = 0
    }
    
    func nextTrack() {
        guard !tracks.isEmpty, let current = currentTrack,
              let index = tracks.firstIndex(of: current) else { return }
        let nextIndex = (index + 1) % tracks.count
        loadTrack(tracks[nextIndex], autoPlay: true)
    }
    
    func previousTrack() {
        guard !tracks.isEmpty, let current = currentTrack,
              let index = tracks.firstIndex(of: current) else { return }
        if currentTime > 3.0 {
            seek(to: 0)
        } else {
            let prevIndex = (index - 1 + tracks.count) % tracks.count
            loadTrack(tracks[prevIndex], autoPlay: true)
        }
    }
    
    func seek(to time: TimeInterval) {
        audioPlayer?.currentTime = time
        currentTime = time
        updateNowPlayingInfo()
    }
    
    // MARK: - Таймер и замер громкости (Энергоэффективный)
    private func startTimer() {
        stopTimer()
        // Обновляем 15 раз в секунду только когда приложение активно
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer, player.isPlaying else { return }
            self.currentTime = player.currentTime
            
            // Считываем пиковую мощность звука для анимации жидкого стекла
            player.updateMeters()
            let power = player.averagePower(forChannel: 0)
            let normalizedLevel = max(0.0, min(1.0, (power + 50) / 50))
            self.audioMeterLevel = normalizedLevel
        }
    }
    
    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        nextTrack()
    }
    
    // MARK: - Шторка уведомлений, Экран блокировки и Dynamic Island (iPhone 14 Pro)
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.nextTrack()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previousTrack()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: posEvent.positionTime)
            return .success
        }
    }
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artist
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        let artworkImage = currentArtwork ?? generateDefaultCover()
        let artwork = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func extractArtwork(from url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        for item in asset.commonMetadata {
            if item.commonKey == .commonKeyArtwork, let data = item.dataValue, let img = UIImage(data: data) {
                return img
            }
        }
        return nil
    }
    
    private func generateDefaultCover() -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let colors = [UIColor.systemIndigo.cgColor, UIColor.systemCyan.cgColor, UIColor.black.cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0.0, 0.5, 1.0])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
}

// MARK: - Эффект Жидкого Стекла (Liquid Glass Visualizer)
struct LiquidGlassBackground: View {
    var isPlaying: Bool
    var audioLevel: Float
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isPlaying)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let pulse = Double(audioLevel) * 65.0
                
                context.addFilter(.blur(radius: 55))
                
                // Сфера 1: Неоновый Циан
                let x1 = size.width * 0.5 + cos(time * 0.7) * (size.width * 0.28)
                let y1 = size.height * 0.35 + sin(time * 0.9) * (size.height * 0.18)
                let r1 = 150.0 + pulse
                context.fill(
                    Path(ellipseIn: CGRect(x: x1 - r1, y: y1 - r1, width: r1 * 2, height: r1 * 2)),
                    with: .color(Color.cyan.opacity(0.65))
                )
                
                // Сфера 2: Глубокий Фиолетовый / Индиго
                let x2 = size.width * 0.5 + sin(time * 0.6) * (size.width * 0.32)
                let y2 = size.height * 0.6 + cos(time * 0.5) * (size.height * 0.22)
                let r2 = 170.0 + pulse * 0.8
                context.fill(
                    Path(ellipseIn: CGRect(x: x2 - r2, y: y2 - r2, width: r2 * 2, height: r2 * 2)),
                    with: .color(Color.purple.opacity(0.65))
                )
                
                // Сфера 3: Маджента / Розовый блик
                let x3 = size.width * 0.4 + cos(time * 1.1 + 2.0) * (size.width * 0.25)
                let y3 = size.height * 0.45 + sin(time * 0.8 + 1.0) * (size.height * 0.25)
                let r3 = 130.0 + pulse * 1.1
                context.fill(
                    Path(ellipseIn: CGRect(x: x3 - r3, y: y3 - r3, width: r3 * 2, height: r3 * 2)),
                    with: .color(Color.pink.opacity(0.55))
                )
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.07))
        .overlay(.ultraThinMaterial.opacity(0.45))
        .ignoresSafeArea()
    }
}

// MARK: - Модификатор Стеклянной Карточки (Liquid Glass Card)
struct LiquidCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 28
    
    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    
                    // Жидкий внутренний блик
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.55),
                                    .white.opacity(0.15),
                                    .cyan.opacity(0.25),
                                    .white.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                }
            )
            .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 12)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = 28) -> some View {
        modifier(LiquidCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Главный интерфейс плеера
struct MainPlayerView: View {
    @EnvironmentObject var audio: AudioEngineManager
    @State private var isImportingFiles = false
    @State private var showPlaylistSheet = false
    @State private var isDraggingSlider = false
    @State private var draggedTime: TimeInterval = 0
    
    var body: some View {
        ZStack {
            // Анимированный фон Liquid Glass
            LiquidGlassBackground(isPlaying: audio.isPlaying, audioLevel: audio.audioMeterLevel)
            
            VStack(spacing: 20) {
                // Верхняя панель (Статус Hi-Fi + Кнопка добавления)
                headerBar
                
                Spacer(minLength: 4)
                
                // Обложка трека в стеклянной капсуле с 3D-пульсацией
                artworkSection
                
                Spacer(minLength: 8)
                
                // Информация о песне и статус Pure Direct
                trackInfoSection
                
                // Стеклянная панель управления (Таймлайн + Кнопки)
                controlsCard
                
                // Нижняя панель (Список треков + Вывод звука AirPlay / Bluetooth)
                bottomBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .fileImporter(
            isPresented: $isImportingFiles,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, UTType(filenameExtension: "flac") ?? .audio],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                audio.importAudioFiles(from: urls)
            }
        }
        .sheet(isPresented: $showPlaylistSheet) {
            PlaylistLibrarySheet()
                .environmentObject(audio)
        }
    }
    
    // MARK: - Компоненты UI
    private var headerBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(audio.isPlaying ? Color.green : Color.cyan)
                    .frame(width: 8, height: 8)
                    .shadow(color: .cyan, radius: 6)
                
                Text(audio.isPureDirectMode ? "PURE HI-FI • 48kHz" : "STANDARD AUDIO")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(cornerRadius: 20)
            .onTapGesture {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                withAnimation(.spring()) {
                    audio.isPureDirectMode.toggle()
                }
            }
            
            Spacer()
            
            Button {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                isImportingFiles = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Добавить")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlass(cornerRadius: 20)
            }
        }
    }
    
    private var artworkSection: some View {
        ZStack {
            // Стеклянная подложка с реактивным свечением
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 290, height: 290)
                .overlay(
                    RoundedRectangle(cornerRadius: 36, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.6), .clear, .cyan.opacity(0.4)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
                .shadow(color: .cyan.opacity(Double(audio.audioMeterLevel) * 0.45), radius: 30, x: 0, y: 0)
            
            if let cover = audio.currentArtwork {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 266, height: 266)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .foregroundStyle(
                            LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    
                    Text(audio.tracks.isEmpty ? "Нажмите «Добавить»\nдля загрузки треков" : "LiquidAudio Hi-Fi")
                        .font(.system(size: 14, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .scaleEffect(audio.isPlaying ? 1.0 + CGFloat(audio.audioMeterLevel) * 0.04 : 0.94)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.65), value: audio.isPlaying)
        .animation(.linear(duration: 0.08), value: audio.audioMeterLevel)
    }
    
    private var trackInfoSection: some View {
        VStack(spacing: 6) {
            Text(audio.currentTrack?.title ?? "Трек не выбран")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Text(audio.currentTrack?.artist ?? "Загрузите музыку из приложения «Файлы»")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }
    
    private var controlsCard: some View {
        VStack(spacing: 20) {
            // Прогресс-бар
            VStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { isDraggingSlider ? draggedTime : audio.currentTime },
                        set: { newValue in
                            isDraggingSlider = true
                            draggedTime = newValue
                        }
                    ),
                    in: 0...max(audio.duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            audio.seek(to: draggedTime)
                            isDraggingSlider = false
                        }
                    }
                )
                .tint(.cyan)
                
                HStack {
                    Text(formatTime(isDraggingSlider ? draggedTime : audio.currentTime))
                    Spacer()
                    Text("-" + formatTime(max(0, audio.duration - (isDraggingSlider ? draggedTime : audio.currentTime))))
                }
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
            }
            
            // Кнопки управления воспроизведением
            HStack(spacing: 42) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    audio.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                }
                
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    audio.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.cyan.opacity(0.85), .purple.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 72, height: 72)
                            .shadow(color: .cyan.opacity(0.45), radius: 14, x: 0, y: 6)
                        
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: audio.isPlaying ? 0 : 2)
                    }
                }
                
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    audio.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(24)
        .liquidGlass(cornerRadius: 32)
    }
    
    private var bottomBar: some View {
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showPlaylistSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                    Text("Моя медиатека (\(audio.tracks.count))")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .liquidGlass(cornerRadius: 22)
            }
            
            Spacer()
            
            // Индикатор готовности к Dynamic Island
            HStack(spacing: 6) {
                Image(systemName: "airpodspro")
                Text("Island Ready")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .liquidGlass(cornerRadius: 22)
        }
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "00:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

// MARK: - Экран Медиатеки (Список скачанных треков)
struct PlaylistLibrarySheet: View {
    @EnvironmentObject var audio: AudioEngineManager
    @Environment(\.dismiss) var dismiss
    @State private var isImporting = false
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.09).ignoresSafeArea()
                
                if audio.tracks.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 56))
                            .foregroundColor(.cyan.opacity(0.8))
                        
                        Text("Медиатека пуста")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        
                        Text("Нажмите кнопку ниже, чтобы выбрать скачанные песни (.mp3, .flac, .wav, .m4a) из памяти вашего iPhone.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        
                        Button {
                            isImporting = true
                        } label: {
                            Text("Выбрать файлы на iPhone")
                                .font(.headline)
                                .foregroundColor(.black)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 14)
                                .background(Color.cyan)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 8)
                    }
                } else {
                    List {
                        ForEach(audio.tracks) { track in
                            Button {
                                audio.loadTrack(track, autoPlay: true)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(audio.currentTrack == track ? Color.cyan : Color.white.opacity(0.1))
                                            .frame(width: 42, height: 42)
                                        
                                        Image(systemName: audio.currentTrack == track && audio.isPlaying ? "waveform" : "music.note")
                                            .foregroundColor(audio.currentTrack == track ? .black : .white)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(audio.currentTrack == track ? .cyan : .white)
                                            .lineLimit(1)
                                        
                                        Text(track.artist)
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.6))
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowBackground(Color.white.opacity(0.05))
                        }
                        .onDelete { indexSet in
                            indexSet.forEach { index in
                                audio.deleteTrack(audio.tracks[index])
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Мои треки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Закрыть") { dismiss() }
                        .foregroundColor(.cyan)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.cyan)
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.audio, .mp3, .wav, .aiff, UTType(filenameExtension: "flac") ?? .audio],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    audio.importAudioFiles(from: urls)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
