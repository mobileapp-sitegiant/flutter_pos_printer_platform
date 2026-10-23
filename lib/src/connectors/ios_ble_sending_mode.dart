/// How iOS sends receipt bytes to a Bluetooth LE printer.
enum IosBleSendingMode {
  /// Paced, command-aligned writer (default).
  paced,

  /// Paced writer, but each image command is sent as one uninterrupted burst.
  imageBurst,

  /// The printer SDK's own writer: 130-byte writes with response.
  sdk,
}
