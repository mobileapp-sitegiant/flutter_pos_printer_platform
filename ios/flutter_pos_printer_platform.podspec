#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_pos_printer_platform.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_pos_printer_platform'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.static_framework = true
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.frameworks = ["SystemConfiguration", "CoreTelephony","WebKit"]

  # libGSDK.a (Gprinter SDK, closed source) only ships a *device* arm64 slice.
  # Linking it into an arm64 simulator build fails, so it is linked for the
  # iphoneos SDK only. On the simulator the Bluetooth connecter is stubbed out
  # (see TARGET_OS_SIMULATOR in ConnecterManager.m) and nothing references it.
  s.preserve_paths = 'libGSDK.a'
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' => '$(inherited) -l"GSDK"',
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => '$(inherited) "${PODS_ROOT}/../.symlinks/plugins/flutter_pos_printer_platform/ios"',
  }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
