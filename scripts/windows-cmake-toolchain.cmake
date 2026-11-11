# Visual Studio is a multi-configuration generator. Its default Debug compiler
# probe uses /Zi, which conflicts with MSVC's deterministic /pathmap flags when
# the PDB output path is remapped. Probe Release without weakening path privacy.
# This does not change the configuration used to build the actual dependency.
set(CMAKE_TRY_COMPILE_CONFIGURATION Release CACHE STRING "Compiler probe configuration" FORCE)
