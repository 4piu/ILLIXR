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
    #
    # branch cpu-incremental-mesh-fix (on top of 7913a0b) fixes two more bugs found while
    # root-causing the ada server/client memory-pressure findings in
    # notes/experiments/multiuser_load/ada_multiuser_plan.md:
    #
    # 657ca2141555209503dbae932ad82dd128b63a90: ITMMeshingEngine_CPU::MeshScene ignored the
    # mesh_type argument entirely and always meshed every valid voxel block, so the
    # "incremental" (mesh_type==1) extraction ada.infinitam actually calls every ~fps_ frames
    # re-extracted and re-serialized the ENTIRE accumulated scene instead of just the blocks
    # fused since the last extraction -- the CUDA engine already filtered by
    # hashEntry.fused_counter > 0 for this case, CPU never did. Compounding that,
    # ITMSceneReconstructionEngine_CPU never overrode ResetActiveSceneTracking (base class
    # default is a no-op), so fused_counter was never reset even if the filter existed. Ported
    # both from the CUDA engine. Confirmed via the ada benchmark: extracted triangle count per
    # periodic pull no longer grows monotonically with total scene size across a run (was
    # 21,901 -> 224,703 triangles over one run; now fluctuates with camera motion instead of
    # climbing).
    #
    # bd33ad8703d0739dfa714bd176676accc12642ba: plugin.cpp's mesh_writer_.put() hardcoded
    # chunk_id to 0 for every OMP thread's chunk instead of using omp_get_thread_num() (the
    # `type` field already did). chunk_id round-trips unchanged through
    # mesh_compression -> server_tx -> network -> device_rx, which routes decode work to one of
    # 8 client-side threads via `chunk_id % chunck_number_` -- always 0 % 8 == 0, so all decode
    # work landed on one thread, leaving 7 of 8 permanently idle. A real, independent
    # parallelism bug, though NOT the driver of the multi-GB client memory growth (that was an
    # unthrottled threadloop spin bug, fixed separately in the main ILLIXR repo's
    # plugins/ada/{device_rx,scene_management,server_rx}).
    #
    # See notes/experiments/multiuser_load/ada_multiuser_plan.md for the full root-cause
    # writeup and validation numbers.
    FetchContent_Declare(InfiniTAM_ext
                         GIT_REPOSITORY https://github.com/4piu/InfiniTAM.git
                         GIT_TAG bd33ad8703d0739dfa714bd176676accc12642ba
    )
    set(ILLIXR_ROOT ${CMAKE_SOURCE_DIR}/include)

    FetchContent_MakeAvailable(InfiniTAM_ext)
    if(TARGET draco_static)
        add_dependencies(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} draco_static)
        target_include_directories(plugin.ada.infinitam${ILLIXR_BUILD_SUFFIX} PUBLIC ${draco_illixr_SOURCE_DIR}/src ${CMAKE_BINARY_DIR})
    endif()
endif()
