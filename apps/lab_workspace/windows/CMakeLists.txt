cmake_minimum_required(VERSION 3.14)
project(lab_workspace LANGUAGES CXX)

set(BINARY_NAME "lab_workspace")
cmake_policy(VERSION 3.14...3.25)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})
add_subdirectory("runner")
include(flutter/generated_plugins.cmake)

set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${FLUTTER_ICU_DATA_FILE}" "${BUILD_BUNDLE_DIR}/icudtl.dat"
  COMMAND ${CMAKE_COMMAND} -E copy_directory "${PROJECT_BUILD_DIR}/flutter_assets" "${BUILD_BUNDLE_DIR}/data/flutter_assets"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${FLUTTER_LIBRARY}" "${BUILD_BUNDLE_DIR}/flutter_windows.dll"
  VERBATIM)
foreach(plugin_library ${PLUGIN_BUNDLED_LIBRARIES})
  add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${plugin_library}" "${BUILD_BUNDLE_DIR}"
    VERBATIM)
endforeach()
