get_external_for_plugin(Draco)
if (NOT Infinitam_FOUND)
    message(STATUS "Downloading InfiniTAM")
    # Forked from ILLIXR/InfiniTAM at dc3c2841a6137c05cf0aef52f1d051c86f3f7b8b to fix plugin.cpp
    # hardcoding MEMORYDEVICE_CUDA/CUDA_TO_CPU/cudaThreadSynchronize unconditionally (broke
    # CPU-only builds even though ITMLib itself already supports DEVICE_CPU end-to-end), plus
    # three separate, non-CUDA-specific bugs found by actually running the ada offload pipeline
    # end-to-end: ITMMesh's constructor allocated a 0-triangle buffer regardless of the
    # requested size (out-of-bounds write, SIGSEGV, on both CPU and CUDA builds);
    # ITMBasicEngine::GetMesh() (the incremental/per-frame extraction path ILLIXR uses) deleted
    # that buffer without reallocating it before MeshScene tried to use it (use-after-free,
    # same symptom); and plugin.cpp itself constructed that mesh with an explicit 0
    # maxTriangles, which combined with the first fix above made noMaxTriangles genuinely 0,
    # underflowing MeshScene's unsigned bound check and writing far past the buffer. See
    # notes/ada_offload_cpu_plan.md for the full writeup.
    FetchContent_Declare(InfiniTAM_ext
                         GIT_REPOSITORY https://github.com/4piu/InfiniTAM.git
                         GIT_TAG 3fda4834bdfe4418ced0f79e35213f743f2b4804
    )
    set(ILLIXR_ROOT ${CMAKE_SOURCE_DIR}/include)

    FetchContent_MakeAvailable(InfiniTAM_ext)
    if(TARGET draco_static)
        add_dependencies(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} draco_static)
        target_include_directories(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} PUBLIC ${draco_illixr_SOURCE_DIR}/src ${CMAKE_BINARY_DIR})
    endif()
endif()
