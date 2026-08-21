import MyMacUI

// The entire app lives in the `MyMacUI` library so it can be tested: SwiftPM
// cannot link a test target against an executable, and the app layer is where
// the sampling lifecycle, the menu bar rendering and every model live. This
// file is the whole executable.
MyMacApp.main()
