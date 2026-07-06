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
                [show_swing_high => 'Swing High'],
                [show_swing_low  => 'Swing Low'],
                [show_hh         => 'HH'],
                [show_hl         => 'HL'],
                [show_lh         => 'LH'],
                [show_ll         => 'LL'],
                [show_bos        => 'BOS'],
                [show_choch      => 'CHOCH'],
                [show_eqh        => 'EQH'],
                [show_eql        => 'EQL'],
            ],
        },
        {
            id => 'structure', label => 'Structure',
            options => [
                [show_internal_zigzag => 'Internal ZigZag'],
                [show_external_zigzag => 'External ZigZag'],
                [show_internal_swings => 'Internal Swings'],
                [show_external_swings => 'External Swings'],
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
                [show_fvg          => 'FVG'],
                [show_orderblocks  => 'Order Blocks'],
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
    return exists $self->{values}{$key} ? ($self->{values}{$key} ? 1 : 0) : 1;
}

sub set {
    my ($self, $key, $value) = @_;
    return $self unless defined $key;
    $self->{values}{$key} = $value ? 1 : 0;
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
        next unless $line =~ /^\s*([a-z0-9_]+)\s*=\s*([01])\s*$/i;
        $self->{values}{$1} = $2 ? 1 : 0;
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
        print {$fh} "$key=" . ($self->{values}{$key} ? 1 : 0) . "\n";
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
    $values{show_internal_zigzag} = 0;
    $values{show_internal_swings} = 0;
    $values{show_internal_liquidity} = 0;
    $values{show_orderblocks} = 0;
    $values{show_anchored_vwap} = 0;
    $values{show_volume_profile} = 0;
    $values{show_signals} = 0;
    $values{show_entries} = 0;
    return \%values;
}

1;
