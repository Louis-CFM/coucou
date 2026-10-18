#!/usr/bin/perl
# Original minimal launcher. Only loads the explicitly supplied local library.
use strict;
use warnings;
use DynaLoader ();
use Cwd qw(abs_path);
my $provided = shift @ARGV;
die "One absolute library path required\n" unless defined($provided) && $provided =~ m{^/} && !@ARGV;
my $path = abs_path($provided);
die "Library unavailable\n" unless defined($path) && -f $path;
my $handle = DynaLoader::dl_load_file($path, 0) or die "Cannot load local bridge\n";
my $symbol = DynaLoader::dl_find_symbol($handle, 'coucou_listen') or die "Bridge entry unavailable\n";
DynaLoader::dl_install_xsub('CoucouLab::listen', $symbol, $path);
CoucouLab::listen();
