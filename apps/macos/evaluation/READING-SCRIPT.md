# English evaluation — reading script

Each sample is one short recording plus the text we expect to hear. We can replay the same audio through different models and compare accuracy and speed without asking you to record it again.

Record one numbered item per file. Read only the quoted text, using your normal voice and pace. Do not say the sample number, filename, or punctuation marks. For samples 17–18, pause naturally between the sentences; for 19–20, read the correction as written.

Run the commands below from `/Users/oleggulevskyy/Documents/dev/nami`. Each command requests microphone access if needed, starts recording when it prints “Speak now…”, and stops automatically after the specified time. The fake engine lets us collect audio without a downloaded model; ignore its placeholder transcript.

The durations are starting points: 10 seconds for short prompts, 15 for medium prompts, and 20 for longer ones. Adjust `--seconds` to your natural reading speed, keeping evaluation clips between 5 and 30 seconds. Avoid excessive trailing silence. If a prompt is too short to be representative, extend it naturally and note the exact words for the reference.

You can start with the first three recordings. For the full set, odd-numbered items are planned for quiet conditions and even-numbered items for ordinary background noise. It is also fine to collect a quiet first pass; tell us the actual conditions so we can update the manifest. Do not add artificial noise just to match a label.

Files are saved under `evaluation/audio/` and existing files are not overwritten. If you stumble or change the wording, keep a note: the reference must match what you actually said. We will verify the references before benchmarking.

## 01 — command · planned: quiet

> Open the project settings and show me the current build configuration.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-01.wav
```

## 02 — command · planned: ordinary background noise

> Search for the session controller and explain how cancellation works.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-02.wav
```

## 03 — command · planned: quiet

> Please move our meeting to tomorrow afternoon at half past three.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-03.wav
```

## 04 — command · planned: ordinary background noise

> Create a new branch for the microphone permission setup.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-04.wav
```

## 05 — names · planned: quiet

> Nami should work in T3 Code, Google Chrome, and Slack.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-05.wav
```

## 06 — names · planned: ordinary background noise

> Send Oleg a reminder to check the WhisperKit benchmark results.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-06.wav
```

## 07 — technical · planned: quiet

> The Swift protocol accepts timestamped audio chunks and returns a final transcript.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-07.wav
```

## 08 — technical · planned: ordinary background noise

> Use AVAudioEngine for capture and Core ML for local inference.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-08.wav
```

## 09 — technical · planned: quiet

> The API request returned a four hundred and twenty nine error.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-09.wav
```

## 10 — technical · planned: ordinary background noise

> Check the JSON payload, the UUID, and the asynchronous callback.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-10.wav
```

## 11 — numbers · planned: quiet

> The median latency is one point two seconds and the memory usage is six hundred megabytes.

```sh
.build/release/nami-bench record --engine fake --seconds 15 --save-audio evaluation/audio/en-11.wav
```

## 12 — numbers · planned: ordinary background noise

> Version one point one point zero needs twenty four evaluation samples.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-12.wav
```

## 13 — long · planned: quiet

> I want to keep the transcription model loaded between recordings because loading it every time would make short dictation sessions feel slow. Please measure the time from the end of recording to the final text.

```sh
.build/release/nami-bench record --engine fake --seconds 20 --save-audio evaluation/audio/en-13.wav
```

## 14 — long · planned: ordinary background noise

> Before we build the menu bar interface, we need to know whether the recognition quality is good enough for everyday messages. Compare quiet recordings with the same kinds of sentences recorded with ordinary background noise.

```sh
.build/release/nami-bench record --engine fake --seconds 20 --save-audio evaluation/audio/en-14.wav
```

## 15 — long · planned: quiet

> When I release the shortcut, insert the transcript into the field where I started speaking. If I have switched to another window while the model was working, keep the text available so I can copy it myself.

```sh
.build/release/nami-bench record --engine fake --seconds 20 --save-audio evaluation/audio/en-15.wav
```

## 16 — long · planned: ordinary background noise

> The first implementation should remain small. Recording, recognition, and text insertion should have separate interfaces so we can replace the model without rewriting the rest of the application.

```sh
.build/release/nami-bench record --engine fake --seconds 20 --save-audio evaluation/audio/en-16.wav
```

## 17 — pauses · planned: quiet

> Let me think about that for a moment. We should probably run the smaller model first.

```sh
.build/release/nami-bench record --engine fake --seconds 15 --save-audio evaluation/audio/en-17.wav
```

## 18 — pauses · planned: ordinary background noise

> The next task is to check permissions. After that, we can test the microphone.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-18.wav
```

## 19 — corrections · planned: quiet

> Schedule it for Tuesday, sorry, Wednesday morning at ten.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-19.wav
```

## 20 — corrections · planned: ordinary background noise

> Use the small model, no, use the large turbo model for the first comparison.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-20.wav
```

## 21 — conversational · planned: quiet

> Hey, I have finished the first pass and will share the results after lunch.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-21.wav
```

## 22 — conversational · planned: ordinary background noise

> That sounds good to me. Could you also check whether it works without an internet connection?

```sh
.build/release/nami-bench record --engine fake --seconds 15 --save-audio evaluation/audio/en-22.wav
```

## 23 — conversational · planned: quiet

> I am not sure we need that feature yet. Let us measure the basic workflow first.

```sh
.build/release/nami-bench record --engine fake --seconds 15 --save-audio evaluation/audio/en-23.wav
```

## 24 — conversational · planned: ordinary background noise

> Thanks for checking. I will take another look when the build has finished.

```sh
.build/release/nami-bench record --engine fake --seconds 10 --save-audio evaluation/audio/en-24.wav
```

## After recording

Keep the WAV files. We will listen back, update a local copy of `samples.template.json` with the exact spoken words and actual conditions, then mark each checked reference as verified. The formal benchmark requires 20–30 samples; a few clips are enough for an initial microphone/model check.

We will compare each transcript with its verified reference and measure warm stop-to-final latency. The proposed targets are median ≤1 second, p95 ≤2 seconds, and at least 90% of samples requiring no word corrections. A synthetic/fake transcript is never evidence of recognition quality.
