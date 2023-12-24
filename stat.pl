#!/usr/bin/perl

use v5.10;
use strict;
use feature 'state';
use utf8;
use open qw( :std :encoding(utf-8) );
use POSIX;
use Data::Dumper;
use Data::Dumper::Concise;

Finance::Math::IRR->import() if defined eval { require Finance::Math::IRR };
warn "try `cpan install Finance::Math::IRR`" unless defined &main::xirr;

############################################################################################
use Getopt::Long qw(:config no_auto_abbrev);
my $help;
my $csvFile;
my $xlsxFile;
my $useApi;
my $hideBalance = 0;
GetOptions(
    'help'            => \$help,
    'xlsx=s'          => \$xlsxFile,
    'csv=s'           => \$csvFile,
    'api'             => \$useApi,
    'hide-balance'  => \$hideBalance,
) or die "bad command line arguments";

if($help || (!$csvFile && !$xlsxFile && !$useApi))
{
    say "отказ от отвественности: автор данной программы не несет никакой ответственности в связи с ее использованием ни перед кем

1. забрать лог транзакций
    тут https://jetlend.ru/invest/v3/notifications внизу зеленая кнопка 'Экспорт операций', жать, сохранить себе файл transactions.xlsx

2. скормить полученный файл этому скрипту
    $0 --xlsx c:/path/to/transactions.xlsx

3. если неосиливается парс екзеля, можно через csv:
    конвертировать полученный файл в .csv, например открыть его в екзеле и сохранить в формате .csv
    разделитель полей - запятая
    без квотирования значений
    и надо чтобы разделитель целой/дробной части в числах был точка

    затем таки скормить полученный файл этому скрипту
        $0 --csv c:/path/to/transactions.csv

4. смотерть результат
    взять комплектный шаблон отсюда https://github.com/vopl/jl/raw/main/stat.xlsx
    скопипастить в него выхлоп скрипта, внимательно проследить чтобы при копипасте не нарушилась табличная структура данных, чтобы все чиселки попали в такие же на шаблоне
    наблюдать графики
        cpy    - Current Percentage Yield, накопленный процентный доход
        apy1   - Annual Percentage Yield, годовая процентная доходность в скользящем окне 1 день
        apy7   - аналогично за неделю
        apy30  - аналогично за месяц
        apy91  - аналогично за квартал
        apyAll - аналогично за весь период
        irr    - Internal rate of return, не будет работать если не обеспечить соответствующий перловый модуль. Но оно в принципе и не надо так как apyAll лучше

замечания можно сливать на гитхаб в раздел issues тут https://github.com/vopl/jl/issues (автор НЕ гарантирует что будет их отрабатывать)

лицензия WTFPL (public domain)";

    exit;
}

############################################################################################
my @events;

if($xlsxFile)
{
    Spreadsheet::ParseXLSX->import() if defined eval { require Spreadsheet::ParseXLSX };
    die "try `cpan install Spreadsheet::ParseXLSX`" unless defined &Spreadsheet::ParseXLSX::new;

    die "file `$xlsxFile' is not found" unless -f $xlsxFile;
    my $parser = Spreadsheet::ParseXLSX->new;
    my $workbook = $parser->parse($xlsxFile);
    die $parser->error() unless $workbook;

    my $worksheet = ($workbook->worksheets())[0] or die "no worksheet found in `$xlsxFile'";
 
    my ($rowMin, $rowMax) = $worksheet->row_range();
    die "malformed structure in `$xlsxFile'" if $rowMax <= $rowMin;
    my ($colMin, $colMax) = $worksheet->col_range();
    die "malformed structure in `$xlsxFile'" if $colMax <= $colMin;
    
    sub val($$)
    {
        my ($row, $col) = @_;
        my $cell = $worksheet->get_cell($row, $col);
        return $cell->value() if $cell;
        return undef;
    }
    
    sub colIdx($)
    {
        my ($key) = @_;
        for my $col ($colMin .. $colMax)
        {
            return $col if $key eq val($rowMin, $col);
        }
        
        return -1;
    }
    
    (my $colDate    = colIdx('Дата'                 )) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colOp      = colIdx('Тип операции'         )) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colIn      = colIdx('Приход'               )) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colOut     = colIdx('Расход'               )) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colChange  = colIdx('Доход после удержания')) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colSIR     = colIdx('НПД'                  )) >=0 or die "malformed structure in `$xlsxFile'";
 
     foreach my $row($rowMin+1 .. $rowMax)
    {
        my $event = { date => val($row, $colDate)};
        
        my $op = val($row, $colOp);
        if('Пополнение счета' eq $op)
        {
            $event->{deposit} += val($row, $colIn);
        }
        elsif('Вывод средств' eq $op)
        {
            $event->{deposit} -= val($row, $colOut);
        }
        elsif('Покупка займа на вторичном рынке' eq $op || 'Продажа займа на вторичном рынке' eq $op)
        {
            $event->{revenue_s} += val($row, $colChange);
            $event->{revenue_s} += val($row, $colSIR);
        }
        else
        {
            $event->{revenue_i} += val($row, $colChange);
        }
        
        push(@events, $event);
    }
}
elsif($csvFile)
{
    open(my $csvHandle, "<$csvFile") or die "can't open `$csvFile': $!";
    my $csv = [map {chomp;[split(',', $_, -1)]} <$csvHandle>];
    close($csvHandle);

    my $header = shift @$csv;
    use List::MoreUtils qw(firstidx);
    (my $colDate    = firstidx {$_ eq 'Дата'                 } @$header) >=0 or die "malformed csv";
    (my $colOp      = firstidx {$_ eq 'Тип операции'         } @$header) >=0 or die "malformed csv";
    (my $colIn      = firstidx {$_ eq 'Приход'               } @$header) >=0 or die "malformed csv";
    (my $colOut     = firstidx {$_ eq 'Расход'               } @$header) >=0 or die "malformed csv";
    (my $colChange  = firstidx {$_ eq 'Доход после удержания'} @$header) >=0 or die "malformed csv";
    (my $colSIR     = firstidx {$_ eq 'НПД'                  } @$header) >=0 or die "malformed csv";

     $colIn     -= scalar @$header;
     $colOut    -= scalar @$header;
     $colChange -= scalar @$header;
     $colSIR    -= scalar @$header;

    foreach my $line(@$csv)
    {
        my $event = { date => $line->[$colDate]};
        
        my $op = $line->[$colOp];
        if('Пополнение счета' eq $op)
        {
            $event->{deposit} += $line->[$colIn];
        }
        elsif('Вывод средств' eq $op)
        {
            $event->{deposit} -= $line->[$colOut];
        }
        elsif('Покупка займа на вторичном рынке' eq $op || 'Продажа займа на вторичном рынке' eq $op)
        {
            $event->{revenue_s} += $line->[$colChange];
            $event->{revenue_s} += $line->[$colSIR];
        }
        else
        {
            $event->{revenue_i} += $line->[$colChange];
        }
        
        push(@events, $event);
    }
}
elsif($useApi)
{
    use lib './lib';
    JL::Api->import() if defined eval { require JL::Api };
    die "no JL::Api available" unless defined &JL::Api::new;
    my $api = JL::Api->new();
    $api->setRetries(0);

    foreach my $rec(@{$api->get('account/notifications/v3', undef, 60*10)})
    {
        my $event = { date => $rec->{date}};
        
        if('110' eq $rec->{event_type})#Пополнение счета
        {
            $event->{deposit} += $rec->{income};
        }
        elsif('120' eq $rec->{event_type})#Вывод со счета
        {
            $event->{deposit} -= $rec->{expense};
        }
        elsif('340' eq $rec->{event_type} || '342' eq $rec->{event_type} || '330' eq $rec->{event_type})#Покупка займа, Покупка по стратегии, Продажа займа
        {
            $event->{revenue_s} += $rec->{summary_interest_rate};
            $event->{revenue_s} += $rec->{revenue};
            $event->{revenue_s} -= $rec->{loss};
        }
        else
        {
            $event->{revenue_i} += $rec->{revenue};
            $event->{revenue_i} -= $rec->{loss};
        }
        
        push(@events, $event);
    }
}
else
{
    die "unknown mode";
}

############################################################################################
{
    my $state = 
    {
        date => undef,
        balance => 0,
        deposit => 0,
        revenue_i => 0,
        revenue_s => 0,
    };
    @events = sort {$a->{date} cmp $b->{date}} @events;
    foreach my $event(@events)
    {
        my $nextDate = parseTs($event->{date});
        $nextDate -= $nextDate % (24*60*60);
        $state->{date} = $nextDate unless $state->{date};
        
        flushDay($state) while $state->{date} < $nextDate;
        
        $state->{deposit} += $event->{deposit};
        $state->{revenue_i} += $event->{revenue_i};
        $state->{revenue_s} += $event->{revenue_s};
    }

    flushDay($state) if $state->{revenue_i} || $state->{revenue_s} || $state->{deposit};
    say "overall balance: ", ($hideBalance ? -1 : sumStr($state->{balance}, !1));
}
exit;



############################################################################################
############################################################################################
############################################################################################
############################################################################################
sub parseTs($)
{
    my ($str) = @_;
    return undef unless $str =~ m/^(\d\d\d\d)-(\d\d)-(\d\d).(\d\d):(\d\d):(\d\d)/;
    return mktime($6, $5, $4, $3, $2-1, $1-1900) + 3*60*60;
}

############################################################################################
sub dateTs($)
{
    my ($unixtime) = @_;
    return strftime("%Y-%m-%d", localtime($unixtime - 3*60*60))
}

############################################################################################
sub sumStr($;$)
{
    my ($s, $compact) = @_;
    $s ||= 0;
    $compact = 1 unless defined $compact;

    my $mult = '';
    if($compact)
    {
        if($s > 1000*1000*1000)
        {
            $s /= 1000*1000*1000;
            $mult = 'G';
        }
        elsif($s > 1000*1000)
        {
            $s /= 1000*1000;
            $mult = 'M';
        }
        elsif($s > 1000)
        {
            $s /= 1000;
            $mult = 'k';
        }
    }

    return sprintf "%.2f%s", $s, $mult;
}

############################################################################################
sub rateStr($;$$)
{
    my ($rate, $nanSym, $suffix) = @_;
    $nanSym = '-' unless defined $nanSym;
    $suffix = '' unless defined $suffix;
    return $nanSym unless defined $rate && $rate eq $rate+0;
    return sprintf("%2.2f%s", $rate*100, $suffix);
}

############################################################################################
sub history()
{
    state $history = [];
    return $history;
}

############################################################################################
sub daysInYear($)
{
    my ($unixtime) = @_;
    return ([localtime($unixtime - 3*60*60)]->[5] % 4) ? 365 : 366;
}

############################################################################################
sub apy($;$)
{
    state $weightLikeXirr = 0;
    
    my $daysAvailable = scalar @{history()};
    
    my ($fetcher, $days) = @_;
    $days = $daysAvailable unless defined $days;
    
    if($days <= $daysAvailable)
    {
        my $sumValue = 0;
        my $sumWeight = 0;
        my $weight = 0;
        
        my $startIdx = $daysAvailable - $days;
        for(my $i=0; $i<$daysAvailable; ++$i)
        {
            my $hrec = history()->[$i];
            
            if($i >= $startIdx && $hrec->{balance} > 0)
            {
                state $log2 = log(2);
                my $value = log(($fetcher->($hrec) + $hrec->{balance}) / $hrec->{balance}) / $log2;
                my $daysInYear = daysInYear($hrec->{date});
                $sumValue += $value * $daysInYear * $weight;
                $sumWeight += $weight;
            }
            
            $weight += $hrec->{deposit} if $weightLikeXirr;
            $weight += $hrec->{deposit} + $fetcher->($hrec) unless $weightLikeXirr;
        }
        
        return (2 ** ($sumValue / $sumWeight)) - 1 if $sumWeight;
    }
    
    return undef;
}

############################################################################################
sub flushDay($)
{
    my ($state) = @_;
    
    push(@{history()}, {%{$state}});
    
    my $fetchers = 
    {
        _i => sub { return $_[0]->{revenue_i}; },
        _s => sub { return $_[0]->{revenue_s}; },
        ''  => sub { return $_[0]->{revenue_i} + $_[0]->{revenue_s}; },
    };
    
    my @fnames = ('_s', '_i', '');
    
    state $headerSayed = 0;
    if(!$headerSayed)
    {
        $headerSayed =1;
        print "date,deposit,balance,irr";
        print ",revenue$_,apy1$_,apy7$_,apy30$_,apy91$_,apyAll$_,cpy$_" foreach(@fnames);
        print "\n";
    }
    
    my $irr;
    if(defined &main::xirr)
    {
        my %cashflow;
        foreach my $hrec(@{history()})
        {
            $cashflow{dateTs($hrec->{date})} = $hrec->{deposit} if $hrec->{deposit};
        }
        $cashflow{dateTs($state->{date})} -= $state->{balance} + $state->{deposit} + $state->{revenue_i} + $state->{revenue_s};
        #warn Dumper(\%cashflow);
        $irr = xirr(%cashflow, precision => 0.00001) if scalar keys %cashflow > 1;
    }
    print join(',', 
        dateTs($state->{date}),
        $hideBalance ? -1 : sumStr($state->{deposit}, !1),
        $hideBalance ? -1 : sumStr($state->{balance}, !1),
        rateStr($irr));

    foreach my $fname(@fnames)
    {
        my $fetcher = $fetchers->{$fname};

        my $apy1  = apy($fetcher, 1);
        my $apy7  = apy($fetcher, 7);
        my $apy30 = apy($fetcher, 30);
        my $apy91 = apy($fetcher, 91);
        my $apyAll = apy($fetcher);
        
        my $daysAvailable = scalar @{history()};
        my $cpy = $apyAll / daysInYear($state->{date}) * ($daysAvailable - 1) if $daysAvailable > 1;

        print ',', join(',', 
            $hideBalance ? -1 : sumStr($fetcher->($state), !1),
            rateStr($apy1),
            rateStr($apy7),
            rateStr($apy30),
            rateStr($apy91),
            rateStr($apyAll),
            rateStr($cpy));
    }
    print "\n";

    if($state->{balance})
    {
        $state->{balance} += $state->{deposit} + $state->{revenue_i} + $state->{revenue_s};
        $state->{deposit} = 0;
        $state->{revenue_i} = 0;
        $state->{revenue_s} = 0;
    }
    else
    {
        $state->{balance} += $state->{deposit};
        $state->{deposit} = 0;
    }

    $state->{date} += 24*60*60;
    
    $headerSayed = 1;
}
