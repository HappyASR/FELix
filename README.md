FELix
==================

FELix is a multiplatform tool for Allwinner processors handling FEL and FES
protocol written in Ruby

* Uses libusb1.0 / ruby 2.0+
* More powerful than fel tool from sunxi-tools
* Easy to improve

Features
------------------

* Write / read memory
* Execute the code at address
* Flash LiveSuit image (at this moment only newer image are supported)
* Extract data from LiveSuit image
* Format the device NAND / Write new MBR
* Enable NAND
* Dump partition from the device
* Display the device info
* Reboot the device


Installation
------------------

1. Install ruby 2.0+ (you can use ruby-installer on Windows)
2. Install bundler
`$ gem install bundler`
3. Run bundler in application directory
`$ bundle`
4. Install libusb (Linux only)
`$ sudo apt-get install libusb1.0.0-dev`
5. Install usb filter (Windows only) on your USB driver. Use [Zadig](http://zadig.akeo.ie/).

Usage
------------------

See `(ruby) felix --help` for available commands

Issues
------------------

As I have limited access to Allwinner devices, I encourage you to report issues
you encounter in Issues section

Todo
------------------

There's a lot of things to do. The most important are:

* Support for legacy image format (partially done)
* Separate command for ~~reading~~/writing NAND partitions
* Improving speed of libsparse / rc6 algorithm
* Partitioning support without sunxi_mbr
