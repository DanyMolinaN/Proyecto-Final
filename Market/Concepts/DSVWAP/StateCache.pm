package Market::Concepts::DSVWAP::StateCache;

use strict;
use warnings;

# =============================================================================
# Modulo: Market::Concepts::DSVWAP::StateCache
# Responsabilidad: Almacena el output final renderizable.
# Es un DTO (Data Transfer Object) inmutable desde la perspectiva de lectura.
# Proporciona a los Overlays datos listos (O(1)) sin lógica matemática.
# =============================================================================

sub new {
    my ($class) = @_;
    my $self = {
        main_vwap      => [], # [ { index, price, dir } ]
        main_bands_u1  => [],
        main_bands_l1  => [],
        main_bands_u2  => [],
        main_bands_l2  => [],
        main_bands_u3  => [],
        main_bands_l3  => [],

        # Línea de la trayectoria (zigzag y rastro ghost)
        zigzag_lines   => [], # [ { x1, y1, x2, y2, color, style } ]
        ghost_levels   => [], # [ { x, y } ]
        ghost_path     => [], # [ { x, y, dir, seq } ]

        # Live Preview (se actualiza solo en el tick actual, nunca se guarda al historial)
        ghost_vwap     => [],
        ghost_bands_u1 => [],
        ghost_bands_l1 => [],
        ghost_bands_u2 => [],
        ghost_bands_l2 => [],
        ghost_bands_u3 => [],
        ghost_bands_l3 => [],
        ghost_line     => undef, # { x1, y1, x2, y2 }
        ghost_label    => undef, # { x, y, dir }
    };
    bless $self, $class;
    return $self;
}

sub clear_all {
    my ($self) = @_;
    $self->{main_vwap} = [];
    $self->{main_bands_u1} = [];
    $self->{main_bands_l1} = [];
    $self->{main_bands_u2} = [];
    $self->{main_bands_l2} = [];
    $self->{main_bands_u3} = [];
    $self->{main_bands_l3} = [];
    $self->{zigzag_lines} = [];
    $self->{ghost_levels} = [];
    $self->{ghost_path} = [];
    $self->clear_ghost();
}

sub clear_main_vwap {
    my ($self) = @_;
    $self->{main_vwap} = [];
    $self->{main_bands_u1} = [];
    $self->{main_bands_l1} = [];
    $self->{main_bands_u2} = [];
    $self->{main_bands_l2} = [];
    $self->{main_bands_u3} = [];
    $self->{main_bands_l3} = [];
}

sub clear_ghost {
    my ($self) = @_;
    $self->{ghost_vwap}     = [];
    $self->{ghost_bands_u1} = [];
    $self->{ghost_bands_l1} = [];
    $self->{ghost_bands_u2} = [];
    $self->{ghost_bands_l2} = [];
    $self->{ghost_bands_u3} = [];
    $self->{ghost_bands_l3} = [];
    $self->{ghost_line}     = undef;
    $self->{ghost_label}    = undef;
    $self->{ghost_path}     = [];
}

1;
