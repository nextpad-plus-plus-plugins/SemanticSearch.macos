cmake_minimum_required(VERSION 3.20)
project(SemanticSearch VERSION 0.1.0 LANGUAGES CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(SCINTILLA_INCLUDE "${NPP_MACOS_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

add_library(SemanticSearch SHARED
    src/PluginEntry.mm
    src/SemanticPanel.mm
    src/SemanticController.mm
    src/engine/AppleNLEmbeddingProvider.mm
    src/engine/MetalSimilarityEngine.mm
    src/engine/SpillableVectorIndex.mm
)
target_include_directories(SemanticSearch PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    src
    src/engine)
# All three frameworks predate the 12.0 deployment target; the macOS-14-only
# NLContextualEmbedding API is @available-guarded in the provider.
target_link_libraries(SemanticSearch PRIVATE
    "-framework Cocoa"
    "-framework NaturalLanguage"
    "-framework Metal"
    "-framework MetalPerformanceShaders")
target_compile_options(SemanticSearch PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(SemanticSearch PROPERTIES PREFIX "" SUFFIX ".dylib")
# Stamp version into the dylib Mach-O current_version (Plugins Admin reads it).
target_link_options(SemanticSearch PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/SemanticSearch")
install(TARGETS SemanticSearch DESTINATION "${PLUGIN_INSTALL_DIR}")

# ── Unit tests (from PR #346, verbatim) ──────────────────────────────────────
enable_testing()
add_executable(semantic_colors_test test/semantic_heatmap_colors_test.cpp)
target_compile_features(semantic_colors_test PRIVATE cxx_std_17)
target_include_directories(semantic_colors_test PRIVATE src/engine)
add_test(NAME semantic_colors COMMAND semantic_colors_test)

add_executable(semantic_index_test test/semantic_index_test.mm
    src/engine/SpillableVectorIndex.mm)
set_target_properties(semantic_index_test PROPERTIES OBJCXX_STANDARD 17)
target_compile_options(semantic_index_test PRIVATE -fobjc-arc)
target_include_directories(semantic_index_test PRIVATE src/engine)
target_link_libraries(semantic_index_test PRIVATE "-framework Foundation")
add_test(NAME semantic_index COMMAND semantic_index_test)
