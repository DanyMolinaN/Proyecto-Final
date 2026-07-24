use strict;
use warnings;

use lib '.';
use Market::MarketData;
use Market::Concepts::DSVWAP::ModularEngine;

my $md = Market::MarketData->new();
open my $fh, '<', 'data/2026_07_20.csv' or die $!;
my $header = <$fh>;
my $counter = 0;
while (my $line = <$fh>) {
    chomp $line;
    my ($ts, $o, $h, $l, $c, $v) = split /,/, $line;
    $v =~ s/\D//g; # clean \r
    $md->add_candle({ timestamp => ++$counter, open => $o+0, high => $h+0, low => $l+0, close => $c+0, volume => ($v||1)+0 });
}
close $fh;

my $eng = Market::Concepts::DSVWAP::ModularEngine->new(length => 50);
my $result = $eng->calculate($md);

for my $k (sort keys %$result) {
    my $v = $result->{$k};
    if (ref $v eq 'ARRAY') { print "  $k => ARRAY(" . scalar(@$v) . ")\n"; }
    elsif (ref $v eq 'HASH') { print "  $k => HASH\n"; }
    else { print "  $k => " . ($v//'undef') . "\n"; }
}
