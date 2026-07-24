package Market::Core::OverlaySettings;

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;

sub new {
    my ($class, %args) = @_;
    my $self = {
        file   => $args{file} || File::Spec->catfile(dirname(__FILE__), '..', '..', '.overlay_settings'),
        values => {},
    };
    bless $self, $class;
    $self->{values} = { %{ _default_values() }, %{ $args{values} || {} } };
    $self->load();
    return $self;
}

sub schema {
    return [
        {
            id => 'price_action', label => 'Price Action',
            options => [
                [show_swing_high     => 'Swing High'],
                [show_swing_low      => 'Swing Low'],
                [show_hh             => 'HH'],
                [show_hl             => 'HL'],
                [show_lh             => 'LH'],
                [show_ll             => 'LL'],
                [show_bos_external   => 'BOS Externo'],
                [show_bos_internal   => 'BOS Interno'],
                [show_choch_external => 'CHoCH Externo'],
                [show_choch_internal => 'CHoCH Interno'],
                [show_eqh            => 'EQH'],
                [show_eql            => 'EQL'],
            ],
        },
        {
            id => 'structure', label => 'Structure',
            options => [
                [show_internal_zigzag => 'Internal ZigZag'],
                [show_external_zigzag => 'External ZigZag'],
                [show_internal_swings => 'Internal Swings'],
                [show_external_swings => 'External Swings'],
                [show_trend_channel       => 'Trendline'],
            ],
        },
        {
            id => 'liquidity', label => 'Liquidity',
            options => [
                [show_liquidity_levels   => 'Liquidity Levels'],
                [show_internal_liquidity => 'Internal Liquidity'],
                [show_external_liquidity => 'External Liquidity'],
                [show_sweeps             => 'Sweep'],
                [show_grabs              => 'Grab'],
                [show_runs               => 'Run'],
            ],
        },
        {
            id => 'smart_money', label => 'Smart Money',
            options => [
                [show_fvg           => 'FVG'],
                [show_ob_external   => 'OB Externo'],
                [show_ob_internal   => 'OB Interno'],
                [show_fibonacci     => 'Fibonacci'],
                [show_supply_demand => 'Supply/Demand'],
            ],
        },
        {
            id => 'volume', label => 'Volume',
            options => [
                [show_anchored_vwap  => 'Anchored VWAP'],
                [show_volume_profile => 'Volume Profile'],
            ],
        },
        {
            id => 'smc_zones', label => 'SMC Zones',
            options => [
                [show_strong_weak_hl  => 'Strong/Weak H&L'],
                [show_premium_discount => 'Premium/Discount'],
                [show_daily_levels    => 'Daily Levels (PDH/PDL)'],
                [show_weekly_levels   => 'Weekly Levels (PWH/PWL)'],
                [show_monthly_levels  => 'Monthly Levels (PMH/PML)'],
            ],
        },
        {
            id => 'zzmtf', label => 'ZZ MTF (Multi-Timeframe)',
            options => [
                [show_zzmtf_internal => 'Internal ZZ MTF'],
                [show_zzmtf_external => 'External ZZ MTF'],
            ],
        },
        {
            id => 'strategies', label => 'Strategies',
            options => [
                [show_signals => 'Signals'],
                [show_entries => 'Entries'],
            ],
        },
    ];
}

sub enabled {
    my ($self, $key) = @_;
    return 1 unless defined $key;
    # Si la clave no existe, retorna 0 (desconocido = desactivado por defecto).
    # Todas las claves válidas están pre-pobladas por _default_values().
    return exists $self->{values}{$key} ? ($self->{values}{$key} ? 1 : 0) : 0;
}

sub set {
    my ($self, $key, $value) = @_;
    return $self unless defined $key;
    # Si es booleano (0 o 1) o undef, forzamos 0/1. Si es string, lo mantenemos.
    if (!defined $value || $value eq '0' || $value eq '1') {
        $self->{values}{$key} = $value ? 1 : 0;
    } else {
        $self->{values}{$key} = $value;
    }
    return $self;
}

sub values {
    my ($self) = @_;
    return $self->{values};
}

sub load {
    my ($self) = @_;
    my $file = $self->{file};
    return $self unless defined $file && -e $file;

    open my $fh, '<', $file or return $self;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*(?:#|$)/;
        if ($line =~ /^\s*([a-z0-9_]+)\s*=\s*([^#]+?)\s*$/i) {
            my ($k, $v) = ($1, $2);
            if ($v eq '0' || $v eq '1') {
                $self->{values}{$k} = $v + 0;
            } else {
                $self->{values}{$k} = $v;
            }
        }
    }
    close $fh;
    return $self;
}

sub save {
    my ($self) = @_;
    my $file = $self->{file};
    return $self unless defined $file;

    open my $fh, '>', $file or return $self;
    print {$fh} "# Chart overlay visibility settings\n";
    for my $key (sort keys %{ $self->{values} || {} }) {
        my $v = $self->{values}{$key};
        $v = ($v ? 1 : 0) if (defined $v && $v =~ /^[01]$/); # sanitizar booleanos
        print {$fh} "$key=$v\n";
    }
    close $fh;
    return $self;
}

sub _default_values {
    my %values;
    for my $category (@{ schema() }) {
        for my $opt (@{ $category->{options} || [] }) {
            my ($key) = @$opt;
            $values{$key} = 1;
        }
    }
    $values{show_internal_zigzag}   = 0;
    $values{show_internal_swings}   = 0;
    $values{show_internal_liquidity} = 0;
    $values{show_ob_external}       = 0;
    $values{show_ob_internal}       = 0;
    # LuxAlgo SMC Pro: Swing OB Count / Internal OB Count (default 5).
    $values{ob_external_count}      = 5;
    $values{ob_internal_count}      = 5;
    $values{show_fibonacci}         = 0;  # default OFF (overlay registrado)
    $values{show_supply_demand}     = 0;  # default OFF (overlay registrado)
    $values{show_anchored_vwap}     = 0;
    $values{show_volume_profile}    = 0;
    $values{show_signals}           = 0;  # sin overlay registrado
    $values{show_entries}           = 0;  # sin overlay registrado
    # BOS/CHoCH externo/interno: default ON para preservar comportamiento previo
    $values{show_bos_external}      = 1;
    $values{show_bos_internal}      = 1;
    $values{show_choch_external}    = 1;
    $values{show_choch_internal}    = 1;
    # SMC Zones: default OFF (nuevos overlays Fase 2)
    $values{show_strong_weak_hl}    = 0;
    $values{show_premium_discount}  = 0;
    $values{show_daily_levels}      = 0;
    $values{show_weekly_levels}     = 0;
    $values{show_monthly_levels}    = 0;
    $values{show_zzmtf_internal}    = 0;
    $values{show_zzmtf_external}    = 0;
    $values{zzmtf_internal_tf}      = '15m';
    $values{zzmtf_external_tf}      = '1h';
    return \%values;
}

1;
