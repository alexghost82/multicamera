cmake_minimum_required(VERSION 3.22)
project(CameraWallGst LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0")
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET gstreamer-1.0 gstreamer-video-1.0 gstreamer-app-1.0)
find_package(JNI REQUIRED)
add_library(camerawallgst SHARED Bridge.mm)
target_include_directories(camerawallgst PRIVATE ${JNI_INCLUDE_DIRS})
target_compile_options(camerawallgst PRIVATE -fobjc-arc)
target_link_libraries(camerawallgst PRIVATE PkgConfig::GST ${JAVA_AWT_LIBRARY}
    "-framework AppKit" "-framework AVFoundation" "-framework QuartzCore" "-framework Security"
    "-framework CoreImage" "-framework ImageIO" "-framework CoreMedia" "-framework CoreVideo")
set_target_properties(camerawallgst PROPERTIES BUILD_RPATH "@loader_path/../../runtime/Contents/Home/lib;$ENV{JAVA_HOME}/lib;/opt/homebrew/lib")
add_custom_command(TARGET camerawallgst POST_BUILD
    COMMAND install_name_tool -change "${JAVA_AWT_LIBRARY}" "@rpath/libjawt.dylib" "$<TARGET_FILE:camerawallgst>")