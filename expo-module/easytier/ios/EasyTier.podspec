# Local Expo module that embeds EasyTier (https://github.com/EasyTier/EasyTier)
# in-process through its C FFI. See docs/easytier/README.md.
#
# The static library comes from EasyTierFFI.xcframework, which is NOT committed:
# `modules/easytier/scripts/fetch-xcframework.js` downloads it into ./Frameworks
# during `npm install` (postinstall) and in EAS Build (eas-build-pre-install).
# If the framework is missing, the module still compiles (the Swift code is
# guarded by EASYTIER_FFI_VENDORED) and `isAvailable()` returns false in JS.

framework_rel_path = 'Frameworks/EasyTierFFI.xcframework'
framework_present = File.exist?(File.join(__dir__, framework_rel_path, 'Info.plist'))

Pod::Spec.new do |s|
  s.name           = 'EasyTier'
  s.version        = '0.1.0'
  s.summary        = 'In-process EasyTier (no TUN, port forwarding only) for Trinity'
  s.description    = 'Runs an EasyTier node inside the app via its C FFI with no_tun = true and exposes local port forwards to JS.'
  s.author         = 'Trinity'
  s.homepage       = 'https://github.com/ZiJie-Duan/easytier-ios-build'
  s.license        = { :type => 'MIT (glue code); bundled EasyTier binary is LGPL-3.0' }
  # The xcframework only ships ios-arm64 and ios-arm64-simulator slices.
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Only the module's own sources; never glob into ./Frameworks.
  s.source_files = '*.{h,m,swift}'

  xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  if framework_present
    s.vendored_frameworks = framework_rel_path

    # System libraries / frameworks the Rust static library links against.
    # NOTE: this list is a best guess for a tokio/rustls-style networking crate on
    # iOS. The authoritative list is `native_static_libs` in BUILD_INFO.txt that the
    # CI (ZiJie-Duan/easytier-ios-build) publishes next to the xcframework; keep the
    # two in sync when bumping the framework. Unresolved symbols at link time usually
    # mean an entry is missing here.
    # native_static_libs from the v2.6.4-1 BUILD_INFO: CoreFoundation, SystemConfiguration, iconv
    # (libc/libm/libSystem are implicit). resolv and Security are kept as cheap insurance.
    s.libraries  = 'resolv', 'iconv'
    s.frameworks = 'SystemConfiguration', 'Security', 'CoreFoundation'

    # Compile the real FFI bindings (see EasyTierModule.swift).
    xcconfig['OTHER_SWIFT_FLAGS'] = '$(inherited) -DEASYTIER_FFI_VENDORED'
    # CocoaPods copies a static-library xcframework slice (lib + Headers incl.
    # module.modulemap) into this directory. Adding it explicitly makes
    # `import EasyTierFFI` resolve even if the importer does not pick the module map
    # up from HEADER_SEARCH_PATHS on its own.
    xcconfig['SWIFT_INCLUDE_PATHS'] = '$(inherited) "${PODS_XCFRAMEWORKS_BUILD_DIR}/EasyTier/Headers"'
    # The xcframework has no x86_64 simulator slice. A generic simulator build
    # (Release, ONLY_ACTIVE_ARCH=NO, e.g. an EAS simulator build) would otherwise also
    # compile this pod for x86_64 and fail with "no such module 'EasyTierFFI'".
    xcconfig['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64'
    s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64' }
  else
    Pod::UI.warn "[EasyTier] #{framework_rel_path} not found - building the EasyTier module " \
                 'without the native library (isAvailable() will be false). ' \
                 'Run `node modules/easytier/scripts/fetch-xcframework.js` and `pod install` again.'
  end

  s.pod_target_xcconfig = xcconfig
end
