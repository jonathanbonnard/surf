# Load RUCKUS library
source -quiet $::env(RUCKUS_DIR)/vivado_proc.tcl

# Load Source Code
if { $::env(VIVADO_VERSION) >= 2015.3 } {
   loadSource -dir  "$::DIR_PATH/rtl"
   loadSource -path "$::DIR_PATH/images/GigEthGth7Core.dcp"
} else {
   puts "\n\nWARNING: $::DIR_PATH requires Vivado 2015.3 (or later)\n\n"
}