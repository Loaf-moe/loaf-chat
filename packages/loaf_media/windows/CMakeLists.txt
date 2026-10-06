cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "loaf_media")
project(${PROJECT_NAME} LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "loaf_media_plugin")

add_library(${PLUGIN_NAME} SHARED
  "include/loaf_media/loaf_media_plugin_c_api.h"
  "include/loaf_media/loaf_media_win.h"
  "loaf_media_plugin_c_api.cpp"
  "loaf_media_plugin.cpp"
  "loaf_media_plugin.h"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Video, the shell and WIC: the Rust crate in rust/, built by cargo and
# linked statically. Release even in a debug app: a debug Media Engine
# pipeline in Rust is needlessly slow, and the crate has its own tests.
set(LOAF_MEDIA_WIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/rust")
set(LOAF_MEDIA_WIN_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/cargo")
set(LOAF_MEDIA_WIN_LIB "${LOAF_MEDIA_WIN_TARGET_DIR}/release/loaf_media_win.lib")
file(GLOB LOAF_MEDIA_WIN_SOURCES CONFIGURE_DEPENDS
  "${LOAF_MEDIA_WIN_DIR}/src/*.rs"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust/loaf_streams/src/*.rs"
  "${CMAKE_CURRENT_SOURCE_DIR}/../rust/loaf_streams/Cargo.toml")
add_custom_command(
  OUTPUT "${LOAF_MEDIA_WIN_LIB}"
  COMMAND cargo build --release --locked
    --manifest-path "${LOAF_MEDIA_WIN_DIR}/Cargo.toml"
    --target-dir "${LOAF_MEDIA_WIN_TARGET_DIR}"
  DEPENDS ${LOAF_MEDIA_WIN_SOURCES}
    "${LOAF_MEDIA_WIN_DIR}/Cargo.toml" "${LOAF_MEDIA_WIN_DIR}/Cargo.lock"
  COMMENT "Building loaf_media_win with cargo"
  VERBATIM
)
add_custom_target(loaf_media_win ALL DEPENDS "${LOAF_MEDIA_WIN_LIB}")
add_dependencies(${PLUGIN_NAME} loaf_media_win)

# What Rust's std needs (`cargo rustc --release -- --print
# native-static-libs`), and the system libraries the crate calls. The
# windows crate links its own imports; these are named anyway so the link
# never depends on that.
target_link_libraries(${PLUGIN_NAME} PRIVATE
  "${LOAF_MEDIA_WIN_LIB}"
  kernel32 advapi32 ntdll userenv ws2_32 bcrypt synchronization
  ole32 oleaut32 shell32 shlwapi
  mfplat mf mfuuid d3d11 dxgi windowscodecs)

set(loaf_media_bundled_libraries
  ""
  PARENT_SCOPE
)
