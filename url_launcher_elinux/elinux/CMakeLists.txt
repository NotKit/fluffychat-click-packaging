cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "url_launcher_elinux")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "url_launcher_elinux_plugin")

find_package(PkgConfig REQUIRED)
pkg_check_modules(GLIB REQUIRED glib-2.0 gio-2.0)

add_library(${PLUGIN_NAME} SHARED
  "url_launcher_elinux_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  ${GLIB_INCLUDE_DIRS}
)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  ${GLIB_LIBRARIES}
)

# glib/gio are core platform libs already present on the device; nothing extra
# needs bundling into the click.
set(url_launcher_elinux_bundled_libraries
  ""
  PARENT_SCOPE
)
