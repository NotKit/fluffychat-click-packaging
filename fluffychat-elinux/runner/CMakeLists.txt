cmake_minimum_required(VERSION 3.15)
project(runner LANGUAGES CXX)

if(FLUTTER_TARGET_BACKEND_TYPE MATCHES "gbm")
  add_definitions(-DFLUTTER_TARGET_BACKEND_GBM)
elseif(FLUTTER_TARGET_BACKEND_TYPE MATCHES "eglstream")
  add_definitions(-DFLUTTER_TARGET_BACKEND_EGLSTREAM)
elseif(FLUTTER_TARGET_BACKEND_TYPE MATCHES "x11")
  add_definitions(-DFLUTTER_TARGET_BACKEND_X11)
else()
  add_definitions(-DFLUTTER_TARGET_BACKEND_WAYLAND)
endif()

find_package(PkgConfig REQUIRED)
pkg_check_modules(GIO REQUIRED IMPORTED_TARGET gio-2.0)
find_package(Threads REQUIRED)

add_executable(${BINARY_NAME}
  "app_url_service.cc"
  "flutter_window.cc"
  "main.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)
apply_standard_settings(${BINARY_NAME})
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GIO Threads::Threads)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
add_dependencies(${BINARY_NAME} flutter_assemble)
