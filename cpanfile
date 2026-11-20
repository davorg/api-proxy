# Keep the application distribution self-contained and use its dependency list
# for installations from the repository root as well.
use File::Basename qw(dirname);
use File::Spec;

my $cpanfile = File::Spec->rel2abs(
    File::Spec->catfile(dirname(__FILE__), 'APIProxy', 'cpanfile')
);
do $cpanfile or die "Cannot load $cpanfile: " . ($@ || $!);
