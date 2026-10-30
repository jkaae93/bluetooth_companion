#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint bluetooth_companion.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'bluetooth_companion'
  s.version          = '0.0.1'
  s.summary          = 'Native Bluetooth LE and Android companion device support.'
  s.description      = <<-DESC
Native Bluetooth LE and Android companion device support.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :type => 'BSD-3-Clause', :file => '../LICENSE' }
  s.author           = { 'Bluetooth Companion' => 'maintainer@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.libraries = 'sqlite3'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'bluetooth_companion_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
