package Market::Concepts::DSVWAP::Normalizer;

# =============================================================================
# Normalizer.pm — Fase 3: Normalizacion z-score sobre features numericas
# =============================================================================
# DISEÑO:
#   - Metodo: z-score (mean, std) calculado SOLO sobre train.
#   - Vacios (undef): ignorados en calculo de params; permanecen vacios en salida.
#   - Categoricas (*_kind) y targets: copiados sin modificar.
#   - std=0: la columna se excluye de normalizacion (se copia tal cual) + warning.
#   - Los params se serializan en JSON para auditabilidad.
#
# INTERFAZ PUBLICA:
#   compute_params($csv_path)                          -> \%params
#   save_params(\%params, $json_path)
#   load_params($json_path)                            -> \%params
#   apply_normalization($csv_in, \%params, $csv_out)
# =============================================================================

use strict;
use warnings;
use Carp qw(croak carp);
use File::Basename qw(dirname);

# Intenta cargar JSON::PP (nucleo en Perl 5.14+), fallback a JSON::XS si existe
my $JSON_BACKEND;
BEGIN {
    if (eval { require JSON::PP; 1 }) {
        $JSON_BACKEND = 'JSON::PP';
    } elsif (eval { require JSON; 1 }) {
        $JSON_BACKEND = 'JSON';
    } else {
        croak "Normalizer.pm necesita JSON::PP (incluido en Perl 5.14+) o JSON";
    }
}

# Columnas que NUNCA se normalizan
my %TARGETS = map { $_ => 1 } qw(trails_3m trails_5m trails_10m trails_15m);
my %META    = map { $_ => 1 } qw(anchor_index);

# Una columna es categorica si su nombre contiene 'kind'
sub _is_categorical { return index($_[0], 'kind') >= 0 }
sub _is_special     { return $TARGETS{$_[0]} || $META{$_[0]} || _is_categorical($_[0]) }

# ---------------------------------------------------------------------------
# compute_params($csv_path) -> \%params
#   Calcula mean y std (population std, ignorando celdas vacias)
#   SOLO sobre las columnas numericas del CSV dado.
#   Devuelve: { col_name => { mean => N, std => N }, ... }
#   Las columnas 100% vacias o con std=0 se excluyen con warnings.
# ---------------------------------------------------------------------------
sub compute_params {
    my ($class_or_self, $csv_path) = @_;
    croak "compute_params: no se encuentra '$csv_path'" unless -f $csv_path;

    open my $fh, '<', $csv_path or croak "No puedo abrir '$csv_path': $!";

    # Leer cabecera
    my $hdr_line = <$fh>;
    chomp $hdr_line;
    my @headers  = split /,/, $hdr_line;

    # Identificar columnas numericas
    my @num_cols = grep { !_is_special($_) } @headers;

    # Acumuladores: suma, suma_sq, conteo por columna
    my %sum  = map { $_ => 0   } @num_cols;
    my %sum2 = map { $_ => 0   } @num_cols;
    my %cnt  = map { $_ => 0   } @num_cols;

    while (my $line = <$fh>) {
        chomp $line;
        next unless $line =~ /\S/;
        my @vals = split /,/, $line, -1;
        my %row;
        @row{@headers} = @vals;

        for my $col (@num_cols) {
            my $v = $row{$col} // '';
            $v =~ s/^\s+|\s+$//g;
            next unless $v =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
            my $fv = $v + 0;
            $sum{$col}  += $fv;
            $sum2{$col} += $fv * $fv;
            $cnt{$col}++;
        }
    }
    close $fh;

    my %params;
    for my $col (@num_cols) {
        my $n = $cnt{$col};
        if ($n == 0) {
            carp "Normalizer WARNING: '$col' tiene 0 valores en train — se omite de normalizacion.";
            next;
        }
        my $mean     = $sum{$col} / $n;
        my $variance = $sum2{$col} / $n - $mean * $mean;
        $variance    = 0 if $variance < 0;  # corrección numérica (floating point)
        my $std      = sqrt($variance);
        if ($std == 0) {
            carp "Normalizer WARNING: '$col' tiene std=0 — se excluye de normalizacion.";
            next;
        }
        $params{$col} = { mean => $mean, std => $std };
    }

    return \%params;
}

# ---------------------------------------------------------------------------
# save_params(\%params, $json_path)
# ---------------------------------------------------------------------------
sub save_params {
    my ($class_or_self, $params, $json_path) = @_;
    croak "save_params: params debe ser HASH ref" unless ref $params eq 'HASH';

    # Redondear a 6 decimales para JSON legible
    my %rounded;
    for my $col (sort keys %$params) {
        $rounded{$col} = {
            mean => _round6($params->{$col}{mean}),
            std  => _round6($params->{$col}{std}),
        };
    }

    my $json_str = _encode_json(\%rounded);

    # Crear directorio si no existe
    my $dir = dirname($json_path);
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }

    open my $fh, '>', $json_path or croak "No puedo escribir '$json_path': $!";
    print $fh $json_str;
    close $fh;
    return $json_path;
}

# ---------------------------------------------------------------------------
# load_params($json_path) -> \%params
# ---------------------------------------------------------------------------
sub load_params {
    my ($class_or_self, $json_path) = @_;
    croak "load_params: no se encuentra '$json_path'" unless -f $json_path;

    open my $fh, '<', $json_path or croak "No puedo abrir '$json_path': $!";
    local $/;
    my $json_str = <$fh>;
    close $fh;

    return _decode_json($json_str);
}

# ---------------------------------------------------------------------------
# apply_normalization($csv_in, \%params, $csv_out)
#   Aplica z-score usando los params dados (siempre los de train).
#   Columnas no en %params se copian tal cual (categoricas, targets, vacios globales).
#   Celdas vacias en columnas normalizables permanecen vacias.
# ---------------------------------------------------------------------------
sub apply_normalization {
    my ($class_or_self, $csv_in, $params, $csv_out) = @_;
    croak "apply_normalization: no se encuentra '$csv_in'" unless -f $csv_in;
    croak "apply_normalization: params debe ser HASH ref" unless ref $params eq 'HASH';

    open my $fh_in,  '<', $csv_in  or croak "No puedo abrir '$csv_in': $!";
    open my $fh_out, '>', $csv_out or croak "No puedo escribir '$csv_out': $!";

    # Cabecera: se copia sin cambios
    my $hdr_line = <$fh_in>;
    chomp $hdr_line;
    my @headers = split /,/, $hdr_line;
    print $fh_out join(',', @headers) . "\n";

    my $rows_written = 0;
    while (my $line = <$fh_in>) {
        chomp $line;
        next unless $line =~ /\S/;

        my @raw_vals = split /,/, $line, -1;
        my %row;
        @row{@headers} = @raw_vals;

        my @out_vals;
        for my $col (@headers) {
            my $v = $row{$col} // '';
            $v =~ s/^\s+|\s+$//g;

            if (exists $params->{$col} && $v =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/) {
                # Normalizar: (v - mean) / std
                my $normed = ($v + 0 - $params->{$col}{mean}) / $params->{$col}{std};
                push @out_vals, $normed;
            } else {
                # Copiar tal cual: categorica, target, vacía, o sin params
                push @out_vals, $v;
            }
        }

        print $fh_out join(',', @out_vals) . "\n";
        $rows_written++;
    }

    close $fh_in;
    close $fh_out;
    return $rows_written;
}

# ---------------------------------------------------------------------------
# Helpers JSON internos (sin dependencias externas pesadas)
# ---------------------------------------------------------------------------
sub _round6 { return defined $_[0] ? int($_[0] * 1_000_000 + 0.5 * ($_[0] >= 0 ? 1 : -1)) / 1_000_000 : undef }

sub _encode_json {
    my ($data) = @_;
    if ($JSON_BACKEND eq 'JSON::PP') {
        my $enc = JSON::PP->new->utf8->pretty->canonical;
        return $enc->encode($data);
    } elsif ($JSON_BACKEND eq 'JSON') {
        my $enc = JSON->new->utf8->pretty->canonical;
        return $enc->encode($data);
    }
    croak "No hay backend JSON disponible";
}

sub _decode_json {
    my ($str) = @_;
    if ($JSON_BACKEND eq 'JSON::PP') {
        return JSON::PP->new->utf8->decode($str);
    } elsif ($JSON_BACKEND eq 'JSON') {
        return JSON->new->utf8->decode($str);
    }
    croak "No hay backend JSON disponible";
}

1;
