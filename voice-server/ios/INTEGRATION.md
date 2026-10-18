# Connecting the iOS app to the voice server

Four small edits plus one new file. **Build on a Mac and test before merging.** This code
was written on Windows and has not been compiled yet.

## 1. Add `VoiceReadout.swift`

Drag `voice-server/ios/VoiceReadout.swift` into the `Pill App/Pill App` folder in Xcode.
The project uses synchronized folders, so it's picked up automatically.

`VoiceServer.baseURL` already points at the hosted server on Vultr:
`https://96-30-206-230.sslip.io`. It uses HTTPS, so it works from any network.

Replace `PASTE_APP_TOKEN_HERE` with the server's app password. Gargi gets it by running
this in her own terminal on her laptop (it isn't in git on purpose):

```
ssh -i ~/.ssh/pillpoint_vultr root@96.30.206.230 "cat /opt/pill-point/app.env"
```

Use the part after `APP_TOKEN=`. Without it, the server answers 401 and the app falls back
to Apple translation.

## 2. Listen button uses the server (`Medicationdetailview.swift`, Prathithi)

The server is tried first (templates + Grok + ElevenLabs). If it can't be reached, the app
falls back to the existing Apple translation + iPhone voice, so nothing breaks offline.

```swift
    @ObservedObject private var speaker = LabelSpeaker.shared
+   @ObservedObject private var voice = VoiceReadout.shared
```

```swift
    private var listenButton: some View {
        Button {
-           if speaker.isSpeaking {
-               speaker.stop()
+           if speaker.isSpeaking || voice.isPlaying {
+               speaker.stop()
+               voice.stop()
            } else {
-               speaker.speak(text: translatedSummary ?? prescription.spokenSummary,
-                             languageCode: translatedSummary == nil ? AppLanguage.english.speechCode : language.speechCode)
+               Task {
+                   let played = await voice.play(prescription, language: language)
+                   if !played {   // server unreachable: on-device translation, as before
+                       speaker.speak(text: translatedSummary ?? prescription.spokenSummary,
+                                     languageCode: translatedSummary == nil ? AppLanguage.english.speechCode : language.speechCode)
+                   }
+               }
            }
        } label: {
            HStack(spacing: 10) {
-               Image(systemName: speaker.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
+               Image(systemName: speaker.isSpeaking || voice.isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white))
-               Text(speaker.isSpeaking ? "Stop" : "Listen")
+               Text(voice.isLoading ? "Loading…" : speaker.isSpeaking || voice.isPlaying ? "Stop" : "Listen")
```

```swift
-       .disabled(isTranslating)
+       .disabled(voice.isLoading)
```

And stop the audio when leaving the screen:

```swift
-       .onDisappear { speaker.stop() }
+       .onDisappear { speaker.stop(); voice.stop() }
```

## 3. Save scans and doses in Tiger Cloud (Aditi's code)

`Labelscannerview.swift`, in `save(_:)`:

```swift
            let prescription = try Prescription.upsert(label, in: modelContext)
+           VoiceServer.sync(prescription)
            onSaved(prescription)
```

`Doseguard.swift`, at the end of `logDose(at:overrodeWarning:in:)`. This one line covers
Home, the pill scanner, and the "Log anyway" warning screen:

```swift
        context.insert(log)
        try? context.save()
+       VoiceServer.syncDose(self, takenAt: date, overrodeWarning: overrodeWarning)
    }
```

Both run in the background and never block or break the app if the server is down.

## 4. Only if you use the laptop instead of Vultr (`Pill-App-Info.plist`)

**Skip this with the hosted server.** It's only needed for a laptop at `http://<laptop IP>:3000`,
because iOS blocks plain `http://` and asks permission for the local network. Replace `<dict/>` with:

```xml
<dict>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
	</dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Pill Point connects to its voice server to read your medication aloud.</string>
</dict>
```

`NSAllowsLocalNetworking` only allows http to local addresses (like `192.168.x.x`), not the
whole internet. A hosted server should use https and doesn't need it.

## 5. Test

1. Check the server is up: open `https://96-30-206-230.sslip.io/health` in Safari. All values should be `true`.
2. Build and run on an iPhone (any network).
3. Scan a bottle, open it, pick a language, tap **Listen**.
4. Turn on Airplane Mode and tap **Listen** again: it should fall back to the iPhone voice.
