# CapsBridge

Use Caps Lock as your screen reader's key in Windows on a Mac.

CapsBridge is for people who run Windows in [VMPal](https://vmpal.com) on a Mac and use a screen reader there. NVDA lets you hold Caps Lock as its modifier key, and so do JAWS and Narrator, which is what most of us do on a laptop keyboard. In a virtual machine on a Mac that doesn't work: you hold Caps Lock, press another key, and the screen reader never notices. CapsBridge fixes that with one button, and takes everything back out with another.

[Download the latest version](https://github.com/AbdulmajeedAlmarzoqi/CapsBridge/releases/latest) · [Website](https://abdulmajeedalmarzoqi.github.io/CapsBridge/) · [بالعربية](https://abdulmajeedalmarzoqi.github.io/CapsBridge/ar/)

## What you need

- A Mac with Apple silicon and macOS 26 or later.
- VMPal with a Windows virtual machine. VMPal Tools have to be installed in it, which VMPal does by itself for the virtual machines it creates.

## Setting it up

1. Download CapsBridge, unzip it and open it. It offers to move itself to the Applications folder. Let it.
2. Press **Set Up**.
3. When it asks, let it restart Windows. Save your work in Windows first.

In Windows, hold Caps Lock and press another key for your screen reader's commands. Press Caps Lock twice quickly to turn Caps Lock itself on or off.

The window lists what CapsBridge checked: VMPal, the Windows virtual machine, its helper on the Mac, the key in Windows, and NVDA's setting. Each line says in words whether it's fine. If something changes later, for instance you take Windows back to an older snapshot, open CapsBridge again. The button then reads **Fix**, and it puts things right.

You don't need to keep the app open. A small helper does the work in the background and starts when you log in.

The app is in English and Arabic, and built to be used with VoiceOver.

## Removing it

Press **Remove CapsBridge…** in the app. It takes the key mapping out of Windows, puts NVDA's setting back the way it found it, removes its helper from the Mac, and offers to move the app to the Trash. Windows goes back to its usual Caps Lock at its next restart.

If you already threw the app away, see [Removing it by hand](#removing-it-by-hand).

## How it works

macOS doesn't tell apps that Caps Lock was pressed and released. It tells them that Caps Lock changed state, once per press. VMPal reads the keyboard through those events, so Windows never sees Caps Lock held down, and a screen reader waiting for "Caps Lock down, then T" never gets it.

CapsBridge goes around that in two steps.

On the Mac, a helper watches which app is in front. While that's the window of a Windows virtual machine you set up, the helper maps Caps Lock to F18, using the same system facility as `hidutil` (`UserKeyMapping`). F18 is an ordinary key, so macOS reports its press and its release, and VMPal passes both on. In every other app the mapping is off and Caps Lock is Caps Lock, for VoiceOver too.

In Windows, one entry in the registry's `Scancode Map` turns F18 back into Caps Lock before anything else sees it. Windows and your screen reader get a real Caps Lock key, held for as long as you hold it.

If NVDA is installed and Caps Lock isn't one of its modifier keys yet, CapsBridge turns that on as well.

## What it changes

On the Mac:

- A login item named CapsBridge, which runs the helper inside the app (`CapsBridge.app/Contents/Library/LoginItems/CapsBridgeHelper.app`).
- The folder `~/Library/Application Support/CapsBridge`, with the list of virtual machines you set up.

The key mapping itself is never saved anywhere. It exists only while the virtual machine's window is in front.

In Windows:

- `HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout\Scancode Map` gets one entry, F18 to Caps Lock. Entries you already have stay as they are.
- `HKLM\SOFTWARE\CapsBridge` holds its notes for undoing that.
- In `%APPDATA%\nvda\nvda.ini`, the Caps Lock bit of `NVDAModifierKeys` is turned on, only when NVDA is installed and it was off. What it was is kept under `HKCU\Software\CapsBridge` so it can be put back.

CapsBridge reaches Windows through VMPal's own command line, which needs the virtual machine's "Allow agent control of this VM" setting. That's on unless you turned it off. If you did, CapsBridge asks before turning it on.

## Screen readers

I use NVDA, and that's what CapsBridge is tested with. JAWS in its laptop layout and Narrator use Caps Lock the same way and get the same real key from Windows, so they should work, but I haven't tried them. If you have, I'd like to hear how it went.

## Removing it by hand

On the Mac, turn CapsBridge off in System Settings, under General, Login Items & Extensions, then delete `~/Library/Application Support/CapsBridge` and the app.

In Windows, open a Command Prompt as administrator and run:

```
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layout" /v "Scancode Map" /f
reg delete "HKLM\SOFTWARE\CapsBridge" /f
```

Then restart Windows. The first line removes every key remapping, so if you remapped other keys with a tool such as SharpKeys, remove only the F18 entry with that tool instead. If CapsBridge turned on Caps Lock in NVDA and you don't want it, uncheck it in NVDA's Preferences, Settings, Keyboard.

## Building it

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
brew install xcodegen
./scripts/build.sh dev
```

That puts the app in `build/CapsBridge.app`, signed for development. Set your own team in `project.yml` first (`DEVELOPMENT_TEAM`). `./scripts/build.sh` without an argument makes a notarized release, and `./scripts/build.sh ci` compiles without signing and runs the tests.

The code is in three parts:

- `Packages/CapsBridgeKit` is everything that isn't interface: the key mapping, VMPal's command line, the `Scancode Map`, NVDA's configuration file. Its tests run with `swift test --package-path Packages/CapsBridgeKit`.
- `Sources/CapsBridgeHelper` is the background helper.
- `Sources/CapsBridge` is the app.

After changing text in the app, `./scripts/check-localization.py` says what's missing from the Arabic translation.

## License

MIT. See [LICENSE](LICENSE).

CapsBridge is not affiliated with VMPal, TablePlus or NV Access.
