/* assets/r-typesheet42.gif, turned into a byte list by xmake's bin2c rule.
 *
 * This is C, not C++, on purpose: xmake scans every C++ file for module
 * imports, sometimes before bin2c has generated the header, which then fails
 * the build. C files are not scanned, and compile after the header exists. */
#include <stddef.h>

const unsigned char ship_sheet_gif[] = {
#include "r-typesheet42.gif.h"
};

const size_t ship_sheet_gif_size = sizeof ship_sheet_gif;
