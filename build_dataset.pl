#!/usr/bin/perl

# =============================================================================
# build_dataset.pl — Fase 2: Generacion de datasets de entrenamiento y test
# =============================================================================
# Uso:
#   perl build_dataset.pl
#
# Genera:
#   output/train_features.csv   <- features de 2026_Abril-Junio.csv
#   output/train_metadata.csv   <- metadata de train
#   output/test_features.csv    <- features de 2026_07_24.csv
#   output/test_metadata.csv    <- metadata de test
# =============================================================================

use strict;
use warnings;

use FindBin qw($Bin);
use lib $Bin;

use Market::MarketData;
use Market::Concepts::DSVWAP::DatasetBuilder;
use File::Spec;
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

sub load_market_data {
    my ($csv_file) = @_;
    die "No se encuentra $csv_file\n" unless -f $csv_file;

    my $md = Market::MarketData->new();
    open(my $fh, '<', $csv_file) or die "No puedo abrir $csv_file: $!";
    my $hdr = <$fh>;
    my $count = 0;
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        my ($timestamp, $open, $high, $low, $close, $volume) = split /,/, $line;
        my $ts = parse_timestamp($timestamp);
        $md->add_candle({
            timestamp => $ts,
            open      => $open  + 0,
            high      => $high  + 0,
            low       => $low   + 0,
            close     => $close + 0,
            volume    => $volume + 0,
        });
        $count++;
    }
    close $fh;
    $md->build_timeframes();
    return ($md, $count);
}

# ---------------------------------------------------------------------------
# Configuracion
# ---------------------------------------------------------------------------
my %DATASETS = (
    train => {
        csv  => File::Spec->catfile($Bin, 'data', '2026_Abril-Junio.csv'),
        feat => File::Spec->catfile($Bin, 'output', 'train_features.csv'),
        meta => File::Spec->catfile($Bin, 'output', 'train_metadata.csv'),
    },
    test => {
        csv  => File::Spec->catfile($Bin, 'data', '2026_07_24.csv'),
        feat => File::Spec->catfile($Bin, 'output', 'test_features.csv'),
        meta => File::Spec->catfile($Bin, 'output', 'test_metadata.csv'),
    },
);

my %OPTS = (
    pip_factor => 4,    # COMEX Gold: 1 tick = $0.25 → pip_factor = 4
    window_1m  => 500,
    window_10m => 300,
);

# ---------------------------------------------------------------------------
# Procesar cada dataset
# ---------------------------------------------------------------------------
my $builder = Market::Concepts::DSVWAP::DatasetBuilder->new();

for my $dataset_name (sort keys %DATASETS) {
    my $cfg = $DATASETS{$dataset_name};

    printf "\n%s\n", "=" x 60;
    printf "DATASET: %s\n", uc($dataset_name);
    printf "%s\n", "=" x 60;

    unless (-f $cfg->{csv}) {
        warn "  WARN: No se encuentra $cfg->{csv} — dataset '$dataset_name' omitido.\n";
        next;
    }

    printf "  Cargando %s ...\n", $cfg->{csv};
    my ($md, $n1m) = load_market_data($cfg->{csv});
    printf "  MarketData: %d velas 1m, %d velas 10m, %d velas 1H\n",
        $n1m,
        scalar(@{ $md->get_data->{'10m'} || [] }),
        scalar(@{ $md->get_data->{'1H'}  || [] });

    printf "  Calculando apariciones + snapshots...\n";
    my $result = $builder->build_dataset($md, %OPTS);

    my $n_rows     = scalar @{ $result->{feature_rows} };
    my $discarded  = $result->{discarded};
    printf "  Filas exportadas: %d | Descartadas: %d\n", $n_rows, $discarded;

    # Estadisticas de celdas vacias por columna
    if ($n_rows > 0) {
        my $sample = $result->{feature_rows}[0];
        my %empty_counts;
        for my $row (@{ $result->{feature_rows} }) {
            for my $col (keys %$row) {
                $empty_counts{$col}++ unless defined $row->{$col};
            }
        }
        my @mostly_empty = grep { ($empty_counts{$_} // 0) / $n_rows > 0.90 }
                           sort keys %empty_counts;
        if (@mostly_empty) {
            printf "  WARN: Columnas >90%% vacias: %s\n", join(', ', @mostly_empty);
        } else {
            printf "  OK: No hay columnas sistematicamente vacias (>90%%).\n";
        }
    }

    printf "  Exportando CSVs...\n";
    $builder->export_csv(
        $result->{feature_rows},
        $result->{meta_rows},
        $cfg->{feat},
        $cfg->{meta},
    );
    printf "  features -> %s\n", $cfg->{feat};
    printf "  metadata -> %s\n", $cfg->{meta};
}

printf "\n%s\n", "=" x 60;
printf "FASE 2 COMPLETA\n";
printf "%s\n", "=" x 60;
