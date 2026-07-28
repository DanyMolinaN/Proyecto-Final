#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;
use Carp qw(croak);

my $JSON_PATH = 'output/normalization_params.json';
open my $fh, '<', $JSON_PATH or croak "No se pudo abrir $JSON_PATH: $!";
local $/;
my $json_text = <$fh>;
close $fh;

my $data = JSON::PP->new->utf8->decode($json_text);

my @targets = qw(trails_3m trails_5m trails_10m trails_15m);
my $found_target = 0;

for my $tgt (@targets) {
    if (exists $data->{$tgt}) {
        print "ERROR: Target '$tgt' fue encontrado en los parametros de normalizacion!\n";
        $found_target = 1;
    }
}

if ($found_target) {
    die "FALLO: Los targets fueron normalizados.\n";
} else {
    print "OK: Ninguno de los targets (trails_*) se encuentra en normalization_params.json.\n";
    print "Confirma que se dejaron en su escala original de conteo entero.\n";
}
