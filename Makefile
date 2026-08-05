IVERILOG ?= iverilog -g2012
VVP      ?= vvp

RTL = rtl
TB  = tb
SIM = sim

.PHONY: all clean tb_mac_rx tb_hw_timestamp tb_udp_classifier tb_rx_descriptor_ring tb_top_integration

all: tb_hw_timestamp tb_mac_rx tb_udp_classifier tb_rx_descriptor_ring tb_top_integration

tb_mac_rx: $(SIM)
	$(IVERILOG) -o $(SIM)/tb_mac_rx.out $(RTL)/mac_rx.v $(TB)/tb_mac_rx.v
	$(VVP) $(SIM)/tb_mac_rx.out

tb_hw_timestamp: $(SIM)
	$(IVERILOG) -o $(SIM)/tb_hw_timestamp.out $(RTL)/hw_timestamp.v $(TB)/tb_hw_timestamp.v
	$(VVP) $(SIM)/tb_hw_timestamp.out

tb_udp_classifier: $(SIM)
	$(IVERILOG) -o $(SIM)/tb_udp_classifier.out $(RTL)/udp_classifier.v $(TB)/tb_udp_classifier.v
	$(VVP) $(SIM)/tb_udp_classifier.out

tb_rx_descriptor_ring: $(SIM)
	$(IVERILOG) -o $(SIM)/tb_rx_descriptor_ring.out $(RTL)/rx_descriptor_ring.v $(TB)/tb_rx_descriptor_ring.v
	$(VVP) $(SIM)/tb_rx_descriptor_ring.out

tb_top_integration: $(SIM)
	$(IVERILOG) -o $(SIM)/tb_top_integration.out \
		$(RTL)/mac_rx.v $(RTL)/hw_timestamp.v $(RTL)/udp_classifier.v $(RTL)/rx_descriptor_ring.v \
		$(TB)/tb_top_integration.v
	$(VVP) $(SIM)/tb_top_integration.out

$(SIM):
	mkdir -p $(SIM)

clean:
	rm -f $(SIM)/*.out $(SIM)/*.vcd $(SIM)/*.log
