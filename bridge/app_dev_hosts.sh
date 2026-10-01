#!/bin/bash
# Fixed-target hosts writer. The GUI runs this only from its verified, root-only
# bundle staging area. Draft bytes travel as base64, never shell source or a path.
# Usage: <non-root uid> <apply|validate> <original sha256> <draft base64>
# validate is read-only and exists for regression tests; it never reads hosts.
set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
unset PERL5OPT PERL5LIB PERLLIB ENV BASH_ENV CDPATH

fail() { printf 'hosts\t%s\n' "$1"; exit "${2:-64}"; }
target_uid="${1:-}"
mode="${2:-}"
expected_sha="${3:-}"
payload="${4:-}"
[[ $# -eq 4 && "$target_uid" =~ ^[0-9]+$ && "$target_uid" -gt 0 ]] || fail invalid
[[ "$mode" == apply || "$mode" == validate ]] || fail invalid
[[ "$expected_sha" =~ ^[a-f0-9]{64}$ ]] || fail invalid
[[ ${#payload} -le 87384 && "$payload" =~ ^[A-Za-z0-9+/=]*$ ]] || fail invalid

if [[ "$mode" == apply ]]; then
    if [[ "${MOLE_TEST_MODE:-0}" == 1 || "${MOLE_TEST_NO_AUTH:-0}" == 1 ]]; then
        printf 'hosts\tskipped\n'
        exit 0
    fi
    [[ "$(/usr/bin/id -u)" -eq 0 ]] || fail unavailable 77
fi

umask 077
scratch=''
replacement=''
cleanup() {
    [[ -z "$scratch" ]] || /bin/rm -f -- "$scratch"
    [[ -z "$replacement" ]] || /bin/rm -f -- "$replacement"
}
trap cleanup EXIT
scratch=$(/usr/bin/mktemp /private/var/tmp/nori-hosts-draft.XXXXXXXX)
printf '%s' "$payload" | /usr/bin/base64 -D > "$scratch" || fail invalid
[[ "$(/usr/bin/stat -f %z "$scratch")" -le 65536 ]] || fail invalid

# Socket is a system Perl module. This does not load or execute draft content.
/usr/bin/perl -T -MSocket=AF_INET,AF_INET6,inet_pton -e '
    use strict; use warnings;
    my %required = ("127.0.0.1\tlocalhost" => 1, "::1\tlocalhost" => 1,
                    "255.255.255.255\tbroadcasthost" => 1);
    my %seen;
    while (my $line = <STDIN>) {
        $line =~ s/\r?\n$//;
        exit 64 if $line =~ /[\x00-\x08\x0a-\x1f\x7f]/;
        $line =~ s/#.*$//;
        next if $line =~ /^\s*$/;
        my @parts = split /[ \t]+/, $line;
        shift @parts if @parts && $parts[0] eq "";
        exit 64 if @parts < 2;
        my $ip = shift @parts;
        exit 64 if $ip =~ /%/;
        exit 64 unless inet_pton(AF_INET, $ip) || inet_pton(AF_INET6, $ip);
        for my $host (@parts) {
            my $name = $host;
            $name =~ s/\.$//;
            exit 64 if !length($name) || length($name) > 253;
            for my $label (split /\./, $name, -1) {
                exit 64 unless length($label) <= 63 && $label =~ /^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/;
            }
            if (lc($name) eq "localhost" || lc($name) eq "broadcasthost") {
                my $mapping = "$ip\t" . lc($host);
                exit 64 unless $required{$mapping};
                $seen{$mapping} = 1;
            }
        }
    }
    exit 64 if grep { !$seen{$_} } keys %required;
' < "$scratch" || fail invalid

if [[ "$mode" == validate ]]; then
    printf 'hosts\tvalid\n'
    exit 0
fi

# /etc is a macOS symlink; use its fixed canonical directory for every write.
# Both the directory and original must be root-owned, regular, and not writable
# by other users. No caller-supplied file path is accepted.
target=/private/etc/hosts
[[ -d /private/etc && ! -L /private/etc ]] || fail unavailable 77
[[ "$(/usr/bin/stat -f %u /private/etc)" -eq 0 ]] || fail unavailable 77
[[ -f "$target" && ! -L "$target" ]] || fail unavailable 77
[[ "$(/usr/bin/stat -f %u "$target")" -eq 0 ]] || fail unavailable 77
directory_mode=$(/usr/bin/stat -f %Lp /private/etc)
file_mode=$(/usr/bin/stat -f %Lp "$target")
(( (8#$directory_mode & 0022) == 0 && (8#$file_mode & 0022) == 0 )) || fail unavailable 77
file_identity=$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp' "$target")
current_sha() { /usr/bin/shasum -a 256 "$target" | /usr/bin/awk '{print $1}'; }
[[ "$(current_sha)" == "$expected_sha" ]] || fail conflict 73

backup=$(/usr/bin/mktemp /private/etc/hosts.nori-backup.XXXXXXXX)
/bin/cp -p "$target" "$backup" || fail failed 74
/bin/chmod 600 "$backup"
/usr/sbin/chown root:wheel "$backup"
replacement=$(/usr/bin/mktemp /private/etc/.nori-hosts.XXXXXXXX)
/bin/cat "$scratch" > "$replacement"
/usr/sbin/chown root:wheel "$replacement"
/bin/chmod "$file_mode" "$replacement"

# Check again immediately before the atomic rename so an old editor draft
# cannot overwrite changes made while authorization or backup was pending.
[[ ! -L "$target" && "$(/usr/bin/stat -f '%d:%i:%u:%g:%Lp' "$target")" == "$file_identity" ]] || fail conflict 73
[[ "$(current_sha)" == "$expected_sha" ]] || fail conflict 73
/bin/mv -f "$replacement" "$target" || fail failed 74
replacement=''
printf 'hosts\tapplied\t%s\n' "$backup"
