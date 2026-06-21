cmake_minimum_required(VERSION 3.15)
set(PROJECT_NAME "content_hub_file_picker")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "content_hub_file_picker_plugin")

find_package(PkgConfig REQUIRED)
pkg_check_modules(GLIB REQUIRED glib-2.0 gio-2.0)
pkg_check_modules(CONTENT_HUB_GLIB REQUIRED libcontent-hub-glib)

add_library(${PLUGIN_NAME} SHARED
  "content_hub_file_picker_plugin.cc"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  ${GLIB_INCLUDE_DIRS}
  ${CONTENT_HUB_GLIB_INCLUDE_DIRS}
)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  ${GLIB_LIBRARIES}
  ${CONTENT_HUB_GLIB_LIBRARIES}
)

# libcontent-hub-glib.so is shipped via clickable's install_lib, not bundled here.
set(content_hub_file_picker_bundled_libraries
  ""
  PARENT_SCOPE
)
