cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "loaf_notify")
project(${PROJECT_NAME} LANGUAGES CXX)
cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "loaf_notify_plugin")

add_library(${PLUGIN_NAME} SHARED
  "include/loaf_notify/loaf_notify_plugin_c_api.h"
  "include/loaf_notify/loaf_notify_win.h"
  "loaf_notify_plugin_c_api.cpp"
  "loaf_notify_plugin.cpp"
  "loaf_notify_plugin.h"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Toasts: the Rust crate in rust/, built by cargo and linked statically.
# Release even in a debug app; the crate has its own tests.
set(LOAF_NOTIFY_WIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/rust")
set(LOAF_NOTIFY_WIN_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/cargo")
set(LOAF_NOTIFY_WIN_LIB "${LOAF_NOTIFY_WIN_TARGET_DIR}/release/loaf_notify_win.lib")
file(GLOB LOAF_NOTIFY_WIN_SOURCES CONFIGURE_DEPENDS
  "${LOAF_NOTIFY_WIN_DIR}/src/*.rs")
add_custom_command(
  OUTPUT "${LOAF_NOTIFY_WIN_LIB}"
  COMMAND cargo build --release --locked
    --manifest-path "${LOAF_NOTIFY_WIN_DIR}/Cargo.toml"
    --target-dir "${LOAF_NOTIFY_WIN_TARGET_DIR}"
  DEPENDS ${LOAF_NOTIFY_WIN_SOURCES}
    "${LOAF_NOTIFY_WIN_DIR}/Cargo.toml" "${LOAF_NOTIFY_WIN_DIR}/Cargo.lock"
  COMMENT "Building loaf_notify_win with cargo"
  VERBATIM
)
add_custom_target(loaf_notify_win ALL DEPENDS "${LOAF_NOTIFY_WIN_LIB}")
add_dependencies(${PLUGIN_NAME} loaf_notify_win)

# What Rust's std needs (`cargo rustc --release -- --print
# native-static-libs`), and the system libraries the crate calls. The
# windows crate links its own imports; these are named anyway so the link
# never depends on that.
target_link_libraries(${PLUGIN_NAME} PRIVATE
  "${LOAF_NOTIFY_WIN_LIB}"
  kernel32 advapi32 ntdll userenv ws2_32 bcrypt synchronization
  ole32 oleaut32 runtimeobject shell32 user32)

set(loaf_notify_bundled_libraries
  ""
  PARENT_SCOPE
)
