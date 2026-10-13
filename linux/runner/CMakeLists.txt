cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "window_chrome.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# Flutter's engine needs two GDK Wayland symbols to link and to start. A GTK
# built for X11 alone has neither, so there the app brings its own. Nothing
# in the runner refers to them, hence --no-as-needed.
pkg_get_variable(GDK_TARGETS gtk+-3.0 targets)
if(GDK_TARGETS AND NOT GDK_TARGETS MATCHES "wayland")
  add_library(gdk-wayland-stub SHARED "gdk_wayland_stub.cc")
  target_link_libraries(gdk-wayland-stub PRIVATE PkgConfig::GTK)
  target_link_libraries(${BINARY_NAME} PRIVATE
    "-Wl,--push-state,--no-as-needed"
    gdk-wayland-stub
    "-Wl,--pop-state"
  )
endif()

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
