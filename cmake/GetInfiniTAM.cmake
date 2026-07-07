get_external_for_plugin(Draco)
if (NOT Infinitam_FOUND)
    message(STATUS "Downloading InfiniTAM")
    # Forked from ILLIXR/InfiniTAM at dc3c2841a6137c05cf0aef52f1d051c86f3f7b8b to fix plugin.cpp
    # hardcoding MEMORYDEVICE_CUDA/CUDA_TO_CPU/cudaThreadSynchronize unconditionally (broke
    # CPU-only builds even though ITMLib itself already supports DEVICE_CPU end-to-end), plus
    # four separate, non-CUDA-specific bugs found by actually running the ada offload pipeline
    # end-to-end: ITMMesh's constructor allocated a 0-triangle buffer regardless of the
    # requested size (out-of-bounds write, SIGSEGV, on both CPU and CUDA builds);
    # ITMBasicEngine::GetMesh() (the incremental/per-frame extraction path ILLIXR uses) deleted
    # that buffer without reallocating it before MeshScene tried to use it (use-after-free,
    # same symptom); plugin.cpp itself constructed that mesh with an explicit 0
    # maxTriangles, which combined with the first fix above made noMaxTriangles genuinely 0,
    # underflowing MeshScene's unsigned bound check and writing far past the buffer; and once
    # that was fixed by using ITMMesh's default capacity, the default itself
    # (SDF_LOCAL_BLOCK_NUM * SDF_BLOCK_SIZE3, sized for a full-scene worst-case export) turned
    # out to be a ~22.5GB allocation, well past this machine's RAM (std::bad_alloc) -- capped
    # at a bounded ~2.1M-triangle buffer sized for a single frame's incremental update instead.
    # See notes/ada_offload_cpu_plan.md for the full writeup.
    FetchContent_Declare(InfiniTAM_ext
                         GIT_REPOSITORY https://github.com/4piu/InfiniTAM.git
                         GIT_TAG 7913a0b83abb43d3e56ebb2fe8cf529fb70e77ce
    )
    set(ILLIXR_ROOT ${CMAKE_SOURCE_DIR}/include)

    FetchContent_MakeAvailable(InfiniTAM_ext)
    if(TARGET draco_static)
        add_dependencies(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} draco_static)
        target_include_directories(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} PUBLIC ${draco_illixr_SOURCE_DIR}/src ${CMAKE_BINARY_DIR})
    endif()
endif()
