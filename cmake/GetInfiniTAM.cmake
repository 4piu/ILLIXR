get_external_for_plugin(Draco)
if (NOT Infinitam_FOUND)
    message(STATUS "Downloading InfiniTAM")
    # Forked from ILLIXR/InfiniTAM at dc3c2841a6137c05cf0aef52f1d051c86f3f7b8b to fix plugin.cpp
    # hardcoding MEMORYDEVICE_CUDA/CUDA_TO_CPU/cudaThreadSynchronize unconditionally, which broke
    # CPU-only builds even though ITMLib itself already supports DEVICE_CPU end-to-end. See
    # notes/ada_offload_cpu_plan.md for the full writeup of what changed and why.
    FetchContent_Declare(InfiniTAM_ext
                         GIT_REPOSITORY https://github.com/4piu/InfiniTAM.git
                         GIT_TAG 31f44c7d6faed7416e9b50123be336bd437bfa3f
    )
    set(ILLIXR_ROOT ${CMAKE_SOURCE_DIR}/include)

    FetchContent_MakeAvailable(InfiniTAM_ext)
    if(TARGET draco_static)
        add_dependencies(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} draco_static)
        target_include_directories(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} PUBLIC ${draco_illixr_SOURCE_DIR}/src ${CMAKE_BINARY_DIR})
    endif()
endif()
