use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use Market::MarketData;
use Market::Concepts::DSVWAP::ModularEngine;
use File::Spec;

my $market = Market::MarketData->new();
my $csv_file = File::Spec->catfile($Bin, 'data', '2026_07_20.csv');
use Time::Piece;
sub parse_timestamp {
    my ($t) = @_;
    return $t + 0 if defined $t && $t =~ /^\d+$/;
    return time unless defined $t && $t =~ /\S/;
    my $s = $t; $s =~ s/:(?=\d{2}$)//;
    my $epoch;
    eval { my $tp = Time::Piece->strptime($s, '%Y-%m-%dT%H:%M:%S%z'); $epoch = $tp->epoch; };
    if ($@) { eval { my $tp = Time::Piece->strptime($s, '%Y-%m-%d %H:%M:%S'); $epoch = $tp->epoch; }; }
    return defined $epoch ? $epoch : time;
}

open my $fh, '<', $csv_file or die "No se pudo abrir CSV '$csv_file': $!";
my $header = <$fh>;
while (my $line = <$fh>) {
    chomp $line;
    next unless $line =~ /\S/;
    my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
    my $ts = parse_timestamp($timestamp);
    $market->add_candle({
        timestamp => $ts,
        open      => $open + 0,
        high      => $high + 0,
        low       => $low + 0,
        close     => $close + 0,
        volume    => $volume + 0,
    });
}
close $fh;
$market->build_timeframes();
print "MarketData size: ", $market->size(), "\n";

my $engine = Market::Concepts::DSVWAP::ModularEngine->new();
my $result = $engine->calculate($market);

my $counter = $result->{_ghost_counter};
my $stats = $counter->count_trails_batch();

printf("Total appearances: %d, Total trails: %d\n", scalar(@{$counter->{history_appearances}}), scalar(@{$counter->{history_trails}}));

my $c = 0;
for my $st (@$stats) {
    if (1) {
        printf("Aparición en index %d (Precio: %.5f, Dir: %d)\n", $st->{anchor_index}, $st->{anchor_price}, $st->{anchor_dir});
        printf("  - Rastros a los 3m : %d\n", $st->{trails_3m});
        printf("  - Rastros a los 5m : %d\n", $st->{trails_5m});
        printf("  - Rastros a los 10m: %d\n", $st->{trails_10m});
        printf("  - Rastros a los 15m: %d\n", $st->{trails_15m});
        
        die "Error de monotonía" unless ($st->{trails_3m} <= $st->{trails_5m} && $st->{trails_5m} <= $st->{trails_10m} && $st->{trails_10m} <= $st->{trails_15m});
        
        $c++;
        last if $c == 3;
    }
}

print "\nMonotonía verificada correctamente para los 3 casos mostrados.\n";
