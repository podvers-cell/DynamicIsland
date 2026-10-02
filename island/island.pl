#!/usr/bin/perl
# Usage: island.pl /path/to/MediaRemoteAdapter.framework sessions|send
# /usr/bin/perl is entitled to MediaRemote; this just calls into island.m.
use strict;
use warnings;
use DynaLoader;
use File::Basename;

my ($framework, $command) = @ARGV;
die "usage: island.pl FRAMEWORK sessions|send\n" unless $framework && $command && $command =~ /^(sessions|send)$/;
my $binary = "$framework/" . basename($framework, ".framework");
my $handle = DynaLoader::dl_load_file($binary, 0) or die "cannot load $binary\n";
my $symbol = DynaLoader::dl_find_symbol($handle, "island_$command") or die "missing island_$command\n";
DynaLoader::dl_install_xsub("main::run", $symbol);
run();
