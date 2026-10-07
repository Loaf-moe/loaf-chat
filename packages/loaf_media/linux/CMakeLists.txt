# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "loaf_media")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "loaf_media_plugin")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "loaf_media_plugin.cc"
  "video_texture.cc"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Video: the Rust crate in rust/ (loafsrc, the players), built by cargo and
# linked statically. GStreamer itself comes from the system.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GST REQUIRED IMPORTED_TARGET
  gstreamer-1.0 gstreamer-base-1.0 gstreamer-app-1.0 gstreamer-video-1.0)

set(LOAF_MEDIA_RS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/rust")
set(LOAF_MEDIA_RS_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/cargo")
set(LOAF_MEDIA_RS_LIB "${LOAF_MEDIA_RS_TARGET_DIR}/release/libloaf_media_rs.a")
file(GLOB LOAF_MEDIA_RS_SOURCES CONFIGURE_DEPENDS "${LOAF_MEDIA_RS_DIR}/src/*.rs"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust/loaf_streams/src/*.rs"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust/loaf_streams/Cargo.toml")
# Release even in a debug app: a debug GStreamer element decoding video
# in Rust is needlessly slow, and the crate has its own tests.
add_custom_command(
  OUTPUT "${LOAF_MEDIA_RS_LIB}"
  COMMAND cargo build --release --locked
    --manifest-path "${LOAF_MEDIA_RS_DIR}/Cargo.toml"
    --target-dir "${LOAF_MEDIA_RS_TARGET_DIR}"
  DEPENDS ${LOAF_MEDIA_RS_SOURCES}
    "${LOAF_MEDIA_RS_DIR}/Cargo.toml" "${LOAF_MEDIA_RS_DIR}/Cargo.lock"
  COMMENT "Building loaf_media_rs with cargo"
  VERBATIM
)
add_custom_target(loaf_media_rs ALL DEPENDS "${LOAF_MEDIA_RS_LIB}")
add_dependencies(${PLUGIN_NAME} loaf_media_rs)

# What `cargo rustc --release -- --print native-static-libs` lists:
# GStreamer (app, base, video, core) with GObject/GLib, GIO, and the C
# runtime pieces Rust's std needs.
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
target_link_libraries(${PLUGIN_NAME} PRIVATE
  "${LOAF_MEDIA_RS_LIB}" PkgConfig::GST PkgConfig::GIO
  gcc_s util rt dl pthread m)
# Keep the crate's Rust std out of the plugin's exported symbols, where it
# could clash with another plugin's.
target_link_options(${PLUGIN_NAME} PRIVATE
  "LINKER:--exclude-libs,libloaf_media_rs.a")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(loaf_media_bundled_libraries
  ""
  PARENT_SCOPE
)

# Native tests, opt-in: cmake -DLOAF_MEDIA_TESTS=ON on a configured app
# build (see test/texture_race_test.cc).
option(LOAF_MEDIA_TESTS "Build loaf_media's native tests" OFF)
if(LOAF_MEDIA_TESTS)
  add_executable(loaf_media_texture_race_test
    "test/texture_race_test.cc"
    "video_texture.cc"
  )
  apply_standard_settings(loaf_media_texture_race_test)
  target_compile_options(loaf_media_texture_race_test PRIVATE
    -fsanitize=address -fno-omit-frame-pointer)
  target_link_options(loaf_media_texture_race_test PRIVATE -fsanitize=address)
  add_dependencies(loaf_media_texture_race_test loaf_media_rs)
  target_link_libraries(loaf_media_texture_race_test PRIVATE
    flutter PkgConfig::GTK
    "${LOAF_MEDIA_RS_LIB}" PkgConfig::GST PkgConfig::GIO
    gcc_s util rt dl pthread m)
endif()
