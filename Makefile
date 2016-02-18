# 'make' builds everything
# 'make clean' deletes everything except source files and Makefile
#
# You need to set NAME, PART and PROC for your project.
# NAME is the base name for most of the generated files.

# solves problem with awk while building linux kernel
# solution taken from http://www.googoolia.com/wp/2015/04/21/awk-symbol-lookup-error-awk-undefined-symbol-mpfr_z_sub/
LD_LIBRARY_PATH =

NAME = oscillo

TMP = tmp

BOARD:=$(shell (python make.py --board $(NAME)) && (cat $(TMP)/$(NAME).board))

VERSION = `git rev-parse --short HEAD`

CORES:=$(shell python make.py --cores $(NAME) && cat $(TMP)/$(NAME).cores)

PART = `cat boards/$(BOARD)/PART`

PATCHES = boards/$(BOARD)/patches

PROC = ps7_cortexa9_0

VIVADO = vivado -nolog -nojournal -mode batch
HSI = hsi -nolog -nojournal -mode batch
RM = rm -rf

UBOOT_TAG = xilinx-v2015.4
LINUX_TAG = xilinx-v2015.4
DTREE_TAG = xilinx-v2015.4

UBOOT_DIR = $(TMP)/u-boot-xlnx-$(UBOOT_TAG)
LINUX_DIR = $(TMP)/linux-xlnx-$(LINUX_TAG)
DTREE_DIR = $(TMP)/device-tree-xlnx-$(DTREE_TAG)

UBOOT_TAR = $(TMP)/u-boot-xlnx-$(UBOOT_TAG).tar.gz
LINUX_TAR = $(TMP)/linux-xlnx-$(LINUX_TAG).tar.gz
DTREE_TAR = $(TMP)/device-tree-xlnx-$(DTREE_TAG).tar.gz

UBOOT_URL = https://github.com/Xilinx/u-boot-xlnx/archive/$(UBOOT_TAG).tar.gz
LINUX_URL = https://github.com/Xilinx/linux-xlnx/archive/$(LINUX_TAG).tar.gz
DTREE_URL = https://github.com/Xilinx/device-tree-xlnx/archive/$(DTREE_TAG).tar.gz

LINUX_CFLAGS = "-O2 -mtune=cortex-a9 -mfpu=neon -mfloat-abi=softfp"
UBOOT_CFLAGS = "-O2 -mtune=cortex-a9 -mfpu=neon -mfloat-abi=softfp"
ARMHF_CFLAGS = "-O2 -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard"

RTL_TAR = $(TMP)/rtl8192cu.tgz
RTL_URL = https://googledrive.com/host/0B-t5klOOymMNfmJ0bFQzTVNXQ3RtWm5SQ2NGTE1hRUlTd3V2emdSNzN6d0pYamNILW83Wmc/rtl8192cu/rtl8192cu.tgz

S3_URL = http://zynq-sdk.s3-website-eu-west-1.amazonaws.com
# Get last app release :
APP_SHA := $(shell curl -s $(S3_URL)/apps | cut -d" " -f1)
APP_URL = $(S3_URL)/app-$(APP_SHA).zip
APP_ZIP = $(TMP)/app.zip

TCP_SERVER_DIR = $(TMP)/$(NAME).tcp-server
TCP_SERVER_SHA = master
PYTHON_DIR = $(TMP)/$(NAME).python
PYTHON_ZIP = $(PYTHON_DIR)/python.zip

ID = $(NAME)-$(VERSION)
SHA:=$(shell printf $(ID) | sha256sum | sed 's/\W//g')

.PRECIOUS: $(TMP)/cores/% $(TMP)/%.xpr $(TMP)/%.hwdef $(TMP)/%.bit $(TMP)/%.fsbl/executable.elf $(TMP)/%.tree/system.dts

all: zip boot.bin uImage devicetree.dtb fw_printenv tcp-server_cli app

$(TMP):
	mkdir -p $(TMP)

zip: tcp-server $(PYTHON_DIR) $(TMP)/$(NAME).bit
	zip --junk-paths $(TMP)/$(ID).zip $(TMP)/$(NAME).bit $(TCP_SERVER_DIR)/tmp/server/kserverd
	mv $(PYTHON_DIR) $(TMP)/py_drivers
	cd $(TMP) && zip $(ID).zip py_drivers/*.py
	rm -r $(TMP)/py_drivers

configs:
	echo $(SHA) > $(TMP)/$(NAME).sha
	python make.py --configs $(NAME) $(VERSION)

app: $(TMP)
	echo $(APP_SHA)
	curl -L $(APP_URL) -o $(APP_ZIP)

$(PYTHON_DIR):
	mkdir -p $@
	python make.py --python $(NAME)

$(TCP_SERVER_DIR):
	git clone https://github.com/Koheron/tcp-server.git $(TCP_SERVER_DIR)
	cd $(TCP_SERVER_DIR) && git checkout $(TCP_SERVER_SHA)
	echo `cd $(TCP_SERVER_DIR) && git rev-parse HEAD` > $(TCP_SERVER_DIR)/VERSION

tcp-server: $(TCP_SERVER_DIR)
	python make.py --middleware $(NAME)
	cd $(TCP_SERVER_DIR) && make CONFIG=config.yaml

tcp-server_cli: $(TCP_SERVER_DIR)
	cd $(TCP_SERVER_DIR) && make -C cli CROSS_COMPILE=arm-linux-gnueabihf- clean all

$(UBOOT_TAR):
	mkdir -p $(@D)
	curl -L $(UBOOT_URL) -o $@

$(LINUX_TAR):
	mkdir -p $(@D)
	curl -L $(LINUX_URL) -o $@

$(DTREE_TAR):
	mkdir -p $(@D)
	curl -L $(DTREE_URL) -o $@

$(RTL_TAR):
	mkdir -p $(@D)
	curl -L $(RTL_URL) -o $@

$(UBOOT_DIR): $(UBOOT_TAR)
	mkdir -p $@
	tar -zxf $< --strip-components=1 --directory=$@
	patch -d $(TMP) -p 0 < $(PATCHES)/u-boot-xlnx-$(UBOOT_TAG).patch
	bash $(PATCHES)/uboot.sh $(PATCHES) $@

$(LINUX_DIR): $(LINUX_TAR) $(RTL_TAR)
	mkdir -p $@
	tar -zxf $< --strip-components=1 --directory=$@
	tar -zxf $(RTL_TAR) --directory=$@/drivers/net/wireless
	patch -d $(TMP) -p 0 < $(PATCHES)/linux-xlnx-$(LINUX_TAG).patch
	bash $(PATCHES)/linux.sh $(PATCHES) $@

$(DTREE_DIR): $(DTREE_TAR)
	mkdir -p $@
	tar -zxf $< --strip-components=1 --directory=$@

uImage: $(LINUX_DIR)
	make -C $< mrproper
	make -C $< ARCH=arm xilinx_zynq_defconfig
	make -C $< ARCH=arm CFLAGS=$(LINUX_CFLAGS) \
	  -j $(shell nproc 2> /dev/null || echo 1) \
	  CROSS_COMPILE=arm-xilinx-linux-gnueabi- UIMAGE_LOADADDR=0x8000 uImage
	cp $</arch/arm/boot/uImage $@

$(TMP)/u-boot.elf: $(UBOOT_DIR)
	mkdir -p $(@D)
	make -C $< mrproper
	make -C $< arch=arm `find $(PATCHES) -name '*_defconfig' -exec basename {} \;`
	make -C $< arch=arm CFLAGS=$(UBOOT_CFLAGS) \
	  CROSS_COMPILE=arm-xilinx-linux-gnueabi- all
	cp $</u-boot $@

fw_printenv: $(UBOOT_DIR) $(TMP)/u-boot.elf
	make -C $< arch=ARM CFLAGS=$(ARMHF_CFLAGS) \
	  CROSS_COMPILE=arm-linux-gnueabihf- env
	cp $</tools/env/fw_printenv $@

boot.bin: $(TMP)/$(NAME).fsbl/executable.elf $(TMP)/$(NAME).bit $(TMP)/u-boot.elf
	echo "img:{[bootloader] $^}" > $(TMP)/boot.bif
	bootgen -image $(TMP)/boot.bif -w -o i $@

devicetree.dtb: uImage $(TMP)/$(NAME).tree/system.dts
	$(LINUX_DIR)/scripts/dtc/dtc -I dts -O dtb -o devicetree.dtb \
	  -i $(TMP)/$(NAME).tree $(TMP)/$(NAME).tree/system.dts

$(TMP)/cores/%: cores/%/core_config.tcl cores/%/*.v
	mkdir -p $(@D)
	$(VIVADO) -source scripts/core.tcl -tclargs $* $(PART)

$(TMP)/%.xpr: configs projects/% $(addprefix $(TMP)/cores/, $(CORES))
	mkdir -p $(@D)
	$(VIVADO) -source scripts/project.tcl -tclargs $* $(PART) $(BOARD)

$(TMP)/%.hwdef: $(TMP)/%.xpr
	mkdir -p $(@D)
	$(VIVADO) -source scripts/hwdef.tcl -tclargs $*

$(TMP)/%.bit: $(TMP)/%.xpr
	mkdir -p $(@D)
	$(VIVADO) -source scripts/bitstream.tcl -tclargs $*

$(TMP)/%.fsbl/executable.elf: $(TMP)/%.hwdef
	mkdir -p $(@D)
	$(HSI) -source scripts/fsbl.tcl -tclargs $* $(PROC)

$(TMP)/%.tree/system.dts: $(TMP)/%.hwdef $(DTREE_DIR)
	mkdir -p $(@D)
	$(HSI) -source scripts/devicetree.tcl -tclargs $* $(PROC) $(DTREE_DIR)
	patch $@ $(PATCHES)/devicetree.patch

clean:
	$(RM) uImage fw_printenv boot.bin devicetree.dtb $(TMP)
	$(RM) .Xil usage_statistics_webtalk.html usage_statistics_webtalk.xml
	$(RM) webtalk*.log webtalk*.jou
