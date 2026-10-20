# CapsBridge

Use Caps Lock as your screen reader key in Windows on a Mac.

In a Windows virtual machine on a Mac, holding Caps Lock does nothing for NVDA, because macOS only tells the virtual machine when Caps Lock turns on or off. CapsBridge fixes that for Windows running in [VMPal](https://vmpal.com).

[Download](https://github.com/AbdulmajeedAlmarzoqi/CapsBridge/releases/latest) · [Website](https://abdulmajeedalmarzoqi.github.io/CapsBridge/) · [العربية](https://abdulmajeedalmarzoqi.github.io/CapsBridge/ar/)

## Requirements

- A Mac with Apple silicon and macOS 26 or later
- VMPal with a Windows virtual machine

## Installing

Download the zip, open CapsBridge, and let it move itself to the Applications folder. Click Set Up, and let it restart Windows when it asks.

## Removing

Click Remove CapsBridge… in the app.

## How it works

While the Windows window is in front, a small helper maps Caps Lock to F18, which macOS passes to the virtual machine like any other key. In Windows, a Scancode Map entry turns F18 back into Caps Lock. If NVDA is installed, CapsBridge also turns on Caps Lock as an NVDA modifier key. On keyboards with a § key, it also swaps § and the key next to the left Shift, which Windows otherwise gets the wrong way round. Everywhere else on the Mac, these keys work as usual.

## Building

```
brew install xcodegen
./scripts/build.sh dev
```

Run the tests with `swift test --package-path Packages/CapsBridgeKit`.

## License

MIT
