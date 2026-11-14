/* Host test: the essential persona's set (the 2D GPU core, every optional GPU
 * feature and the cursor absent: their calls are inline stubs), two LUT banks,
 * the DPI driver (the DBI calls stubs too); the HDMI options at run time */
#define BLNS_HW_GPU         1
#define BLNS_HW_GPU_XY      0
#define BLNS_HW_GPU_GRAD    0
#define BLNS_HW_GPU_BLEND   0
#define BLNS_HW_GPU_TRI     0
#define BLNS_HW_GPU_REMAP   0
#define BLNS_HW_GPU_MPLANE  0
#define BLNS_HW_GPU_IMM     0
#define BLNS_HW_GPU_LINE    0
#define BLNS_HW_CURSOR      0
#define BLNS_HW_LUT         1
#define BLNS_HW_LUT2        1
#define BLNS_HW_DPI         1
#define BLNS_HW_DBI         0
