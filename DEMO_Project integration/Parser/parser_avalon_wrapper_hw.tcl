package require -exact qsys 15.0

# 
# module parser_avalon_wrapper
# 
set_module_property DESCRIPTION "ITCH Parser Hardware Wrapper"
set_module_property NAME parser_avalon_wrapper
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property GROUP "Custom IP"
set_module_property AUTHOR "Antigravity"
set_module_property DISPLAY_NAME "ITCH Parser Hardware Wrapper"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false
set_module_property REPORT_HIERARCHY false

# 
# file sets
# 
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL parser_avalon_wrapper
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false
set_fileset_property QUARTUS_SYNTH ENABLE_FILE_OVERWRITE_MODE false
add_fileset_file parser_avalon_wrapper.sv SYSTEM_VERILOG PATH parser_avalon_wrapper.sv TOP_LEVEL_FILE
add_fileset_file parser.sv SYSTEM_VERILOG PATH parser.sv

# Orderbook dependencies
add_fileset_file ob_pkg.sv SYSTEM_VERILOG PATH ../Orderbook/ob_pkg.sv
add_fileset_file ob_opb.sv SYSTEM_VERILOG PATH ../Orderbook/ob_opb.sv
add_fileset_file ob_flb_bid.sv SYSTEM_VERILOG PATH ../Orderbook/ob_flb_bid.sv
add_fileset_file ob_flb_ask.sv SYSTEM_VERILOG PATH ../Orderbook/ob_flb_ask.sv
add_fileset_file orderbook.sv SYSTEM_VERILOG PATH ../Orderbook/orderbook.sv
add_fileset_file flb_refill_engine_bid_1024.sv SYSTEM_VERILOG PATH ../Orderbook/flb_refill_engine_bid_1024.sv
add_fileset_file flb_refill_engine_ask_1024.sv SYSTEM_VERILOG PATH ../Orderbook/flb_refill_engine_ask_1024.sv
add_fileset_file pe_msb32.sv SYSTEM_VERILOG PATH ../Orderbook/pe_msb32.sv
add_fileset_file pe_lsb32.sv SYSTEM_VERILOG PATH ../Orderbook/pe_lsb32.sv
add_fileset_file pe_msb128.sv SYSTEM_VERILOG PATH ../Orderbook/pe_msb128.sv
add_fileset_file pe_lsb128.sv SYSTEM_VERILOG PATH ../Orderbook/pe_lsb128.sv

# 
# parameters
# 

# 
# display items
# 

# 
# connection point clock
# 
add_interface clock clock end
set_interface_property clock clockRate 0
set_interface_property clock ENABLED true
set_interface_property clock EXPORT_OF ""
set_interface_property clock PORT_NAME_MAP ""
set_interface_property clock CMSIS_SVD_VARIABLES ""
set_interface_property clock SVD_ADDRESS_GROUP ""

add_interface_port clock clk clk Input 1

# 
# connection point reset
# 
add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
set_interface_property reset ENABLED true
set_interface_property reset EXPORT_OF ""
set_interface_property reset PORT_NAME_MAP ""
set_interface_property reset CMSIS_SVD_VARIABLES ""
set_interface_property reset SVD_ADDRESS_GROUP ""

add_interface_port reset reset_n reset_n Input 1

# 
# connection point s0
# 
add_interface s0 avalon end
set_interface_property s0 addressUnits WORDS
set_interface_property s0 associatedClock clock
set_interface_property s0 associatedReset reset
set_interface_property s0 bitsPerSymbol 8
set_interface_property s0 burstOnBurstBoundariesOnly false
set_interface_property s0 burstcountUnits WORDS
set_interface_property s0 explicitAddressSpan 0
set_interface_property s0 holdTime 0
set_interface_property s0 linewrapBursts false
set_interface_property s0 maximumPendingReadTransactions 0
set_interface_property s0 maximumPendingWriteTransactions 0
set_interface_property s0 readLatency 0
set_interface_property s0 readWaitTime 1
set_interface_property s0 setupTime 0
set_interface_property s0 timingUnits Cycles
set_interface_property s0 writeWaitTime 0
set_interface_property s0 ENABLED true
set_interface_property s0 EXPORT_OF ""
set_interface_property s0 PORT_NAME_MAP ""
set_interface_property s0 CMSIS_SVD_VARIABLES ""
set_interface_property s0 SVD_ADDRESS_GROUP ""

add_interface_port s0 avs_address address Input 6
add_interface_port s0 avs_read read Input 1
add_interface_port s0 avs_readdata readdata Output 32
add_interface_port s0 avs_write write Input 1
add_interface_port s0 avs_writedata writedata Input 32
set_interface_assignment s0 embeddedsw.configuration.isFlash 0
set_interface_assignment s0 embeddedsw.configuration.isMemoryDevice 0
set_interface_assignment s0 embeddedsw.configuration.isNonVolatileStorage 0
set_interface_assignment s0 embeddedsw.configuration.isPrintableDevice 0
