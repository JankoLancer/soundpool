import Flutter
import UIKit
import AVFoundation


public class SwiftSoundpoolPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "pl.ukaszapps/soundpool", binaryMessenger: registrar.messenger())
        let instance = SwiftSoundpoolPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        configureAudioSession()
    }
    private lazy var wrappers = [SwiftSoundpoolPlugin.SoundpoolWrapper]()
    
    public static func configureAudioSession(){
        do {
            let audioSession = AVAudioSession.sharedInstance()
            if #available(iOS 10.0, *) {
                try audioSession.setCategory(AVAudioSession.Category.playback, mode: AVAudioSession.Mode.default, options: [AVAudioSession.CategoryOptions.allowAirPlay, AVAudioSession.CategoryOptions.mixWithOthers])
            } else {
                try audioSession.setCategory(AVAudioSession.Category.playback, options: [AVAudioSession.CategoryOptions.mixWithOthers])
            }
        }
        catch {
            print("Unexpected error: \(error).")
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initSoundpool":
            // TODO create distinction between different types of audio playback
            let attributes = call.arguments as! NSDictionary
            let maxStreams = attributes["maxStreams"] as! Int
            let wrapper = SoundpoolWrapper(maxStreams)
            let index = wrappers.count
            wrappers.append(wrapper)
            result(index)
        case "dispose":
            let attributes = call.arguments as! NSDictionary
            let index = attributes["poolId"] as! Int
            
            guard let wrapper = wrapperById(id: index) else {
                print("Dispose attempt on not available pool (id: \(index)).")
                result(FlutterError( code: "invalidArgs",
                                     message: "Invalid poolId",
                                     details: "Pool with id \(index) not found" ))
                break
            }
            wrapper.stopAllStreams()
            wrappers.remove(at: index)
            result(nil)
        default:
            let attributes = call.arguments as! NSDictionary
            let index = attributes["poolId"] as! Int
            
            guard let wrapper = wrapperById(id: index) else {
                print("Action '\(call.method)' attempt on not available pool (id: \(index)).")
                result(FlutterError( code: "invalidArgs",
                                     message: "Invalid poolId",
                                     details: "Pool with id \(index) not found" ))
                break
            }
            wrapper.handle(call, result: result)
        }
    }
    
    private func wrapperById(id: Int) -> SwiftSoundpoolPlugin.SoundpoolWrapper? {
        if (id >= wrappers.count || id < 0){
            return nil
        }
        let wrapper = wrappers[id]
        return wrapper
    }
    
    class SoundpoolWrapper : NSObject {
        private var maxStreams: Int
        
        private var streamIdProvider = Atomic<Int>(0)
        
        private lazy var soundpool = [AVAudioPlayer]()
        
        private lazy var streamsCount: Dictionary<Int, Int> = [Int: Int]()
        
        private lazy var nowPlaying: Dictionary<Int, NowPlaying> = [Int: NowPlaying]()
        
        init(_ maxStreams: Int){
            self.maxStreams = maxStreams
        }
        
        public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
            let attributes = call.arguments as! NSDictionary
//            print("\(call.method): \(attributes)")
            switch call.method {
            case "load":
                let rawSound = attributes["rawSound"] as! FlutterStandardTypedData
                do {
                    let audioPlayer = try AVAudioPlayer(data: rawSound.data)
                    audioPlayer.enableRate = true
                    audioPlayer.prepareToPlay()
                    let index = soundpool.count
                    soundpool.append(audioPlayer)
                    result(index)
                } catch {
                    result(-1)
                }
            case "loadUri":
                let soundUri = attributes["uri"] as! String
                
                let url = URL(string: soundUri)
                if (url != nil){
                    DispatchQueue.global(qos: .utility).async {
                        do {
                            let cachedSound = try Data(contentsOf: url!, options: NSData.ReadingOptions.mappedIfSafe)
                            DispatchQueue.main.async {
                                var value:Int = -1
                                do {
                                    let audioPlayer = try AVAudioPlayer(data: cachedSound)
                                    audioPlayer.enableRate = true
                                    audioPlayer.prepareToPlay()
                                    let index = self.self.soundpool.count
                                    self.self.soundpool.append(audioPlayer)
                                    value = index
                                } catch {
                                    print("Unexpected error while preparing player: \(error).")
                                }
                                result(value)
                            }
                        } catch {
                            print("Unexpected error while downloading file: \(error).")
                            DispatchQueue.main.async {
                                result(-1)
                            }
                        }
                    }
                } else {
                    result(-1)
                }
            case "play":
                let soundId = attributes["soundId"] as! Int
                let times = attributes["repeat"] as? Int
                let rate = (attributes["rate"] as? Double) ?? 1.0
                if (soundId < 0){
                    result(0)
                    break
                }
                
                guard var audioPlayer = playerBySoundId(soundId: soundId) else {
                    result(0)
                    break
                }
                do {
                    let currentCount = streamsCount[soundId] ?? 0

                    if (currentCount >= maxStreams){
                        result(0)
                        break
                    }
                    
                    let nowPlayingData: NowPlaying
                    let streamId: Int = streamIdProvider.increment()
                    
                    let delegate = SoundpoolDelegate(pool: self, soundId: soundId, streamId: streamId)
                    audioPlayer.delegate = delegate
                    nowPlayingData =  NowPlaying(player: audioPlayer, delegate: delegate)
                    
                    audioPlayer.numberOfLoops = times ?? 0
                    audioPlayer.enableRate = true
                    audioPlayer.rate = Float(rate)
                    
                    if (audioPlayer.play()) {
                        streamsCount[soundId] = currentCount + 1
                        nowPlaying[streamId] = nowPlayingData
                        result(streamId)
                    } else {
                        result(0) // failed to play sound
                    }
                    // lets recreate the audioPlayer for next request - setting numberOfLoops has initially no effect
                    
                    if let previousData = audioPlayer.data {
                        audioPlayer = try AVAudioPlayer(data: previousData)
                    } else if let previousUrl = audioPlayer.url {
                        audioPlayer = try AVAudioPlayer(contentsOf: previousUrl)
                    }
                    
                    audioPlayer.prepareToPlay()
                    soundpool[soundId] = audioPlayer
                } catch {
                    print("Unexpected error play: \(error).")
                    result(0)
                }
            case "pause":
                let streamId = attributes["streamId"] as! Int
                if let playingData = playerByStreamId(streamId: streamId) {
                    playingData.player.pause()
                    result(streamId)
                } else {
                    result (-1)
                }
            case "resume":
                let streamId = attributes["streamId"] as! Int
                if let playingData = playerByStreamId(streamId: streamId) {
                    playingData.player.play()
                    result(streamId)
                } else {
                    result (-1)
                }
            case "stop":
                let streamId = attributes["streamId"] as! Int
                if let nowPlaying = playerByStreamId(streamId: streamId) {
                    let audioPlayer = nowPlaying.player
                    audioPlayer.stop()
                    result(streamId)
                    // removing player
                    self.nowPlaying.removeValue(forKey: streamId)
                    nowPlaying.delegate.decreaseCounter()
                    audioPlayer.delegate = nil
                } else {
                    result(-1)
                }
            case "setVolume":
                let streamId = attributes["streamId"] as? Int
                let soundId = attributes["soundId"] as? Int
                let volume = attributes["volumeLeft"] as! Double
                
                var audioPlayer: AVAudioPlayer? = nil;
                if (streamId != nil){
                    audioPlayer = playerByStreamId(streamId: streamId!)?.player
                } else if (soundId != nil){
                    audioPlayer = playerBySoundId(soundId: soundId!)
                }
                audioPlayer?.volume = Float(volume)
                result(nil)
            case "setRate":
                let streamId = attributes["streamId"] as! Int
                let rate = (attributes["rate"] as? Double) ?? 1.0
                let audioPlayer: AVAudioPlayer? = playerByStreamId(streamId: streamId)?.player
                audioPlayer?.rate = Float(rate)
                result(nil)
            case "release": // TODO this should distinguish between soundpools for different types of audio playbacks
                stopAllStreams()
                soundpool.removeAll()
                result(nil)
            default:
                result("notImplemented")
            }
        }
        
        func stopAllStreams() {
            for audioPlayer in soundpool {
                audioPlayer.stop()
            }
        }
        private func playerByStreamId(streamId: Int) -> NowPlaying? {
            let audioPlayer = nowPlaying[streamId]
            return audioPlayer
        }
        
        private func playerBySoundId(soundId: Int) -> AVAudioPlayer? {
            if (soundId >= soundpool.count || soundId < 0){
                return nil
            }
            let audioPlayer = soundpool[soundId]
            return audioPlayer
        }
        
        private class SoundpoolDelegate: NSObject, AVAudioPlayerDelegate {
            private var soundId: Int
            private var streamId: Int
            private var pool: SoundpoolWrapper
            init(pool: SoundpoolWrapper, soundId: Int, streamId: Int) {
                self.soundId = soundId
                self.pool = pool
                self.streamId = streamId
            }
            func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
                decreaseCounter()
            }
            func decreaseCounter(){
                pool.streamsCount[soundId] = (pool.streamsCount[soundId] ?? 1) - 1
                pool.nowPlaying.removeValue(forKey: streamId)
            }
        }
        
        private struct NowPlaying {
            let player: AVAudioPlayer
            let delegate: SoundpoolDelegate
        }
    }
}

