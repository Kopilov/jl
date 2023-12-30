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
my $hideMoney = 0;
GetOptions(
    'help'            => \$help,
    'xlsx=s'          => \$xlsxFile,
    'csv=s'           => \$csvFile,
    'api'             => \$useApi,
    'hide-money'      => \$hideMoney,
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
    наблюдать графики, легенда:
        семантика
            cpy - Current Percentage Yield, доход кумулятивно в процентах
            apy - Annual Percentage Yield, доходность годовых
            irr - Internal Rate of Return, это то что все считают по функции XIRR, практически то же самое что 'apy' (не будет работать если не обеспечить соответствующий перловый модуль)
        
        суффиксы для окон
            7     - значение взято по скользящему окну размером в неделю
            30    - в месяц
            91    - в квартал
            пусто - без окон, просто за за весь доступный период
        
        суффиксы для типов доходностей
            _i    - инвестиционная часть доходности
            _s    - спекулятивная (в связи с операциями на вторичке по ценам отличным от 100%)
            _o    - остальная (тут например бонусы)
            пусто - это суммарно все вышеперечисленные типы

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
    (my $colDebt    = colIdx('Основной долг'        )) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colRevenue = colIdx('Доход после удержания')) >=0 or die "malformed structure in `$xlsxFile'";
    (my $colSIR     = colIdx('НПД'                  )) >=0 or die "malformed structure in `$xlsxFile'";
 
     foreach my $row($rowMin+1 .. $rowMax)
    {
        my $event = { date => val($row, $colDate)};
        
        my $op = val($row, $colOp);
        if('Пополнение счета' eq $op || 'Вывод средств' eq $op)
        {
            $event->{deposit} += val($row, $colIn) - val($row, $colOut);
        }
        elsif('Платеж по займу' eq $op || 'Дефолт' eq $op || 'Зачисление по судебному взысканию' eq $op)
        {
            $event->{revenue_i} += val($row, $colRevenue);
        }
        elsif('Покупка займа на вторичном рынке' eq $op || 'Продажа займа на вторичном рынке' eq $op)
        {
            $event->{revenue_i} += val($row, $colSIR);
            $event->{revenue_s} += val($row, $colRevenue);
        }
        else
        {
            $event->{revenue_o} += val($row, $colRevenue);
        }

        $event->{assetChange} += val($row, $colDebt);
        $event->{assetChange} += val($row, $colRevenue) if 'Дефолт' eq $op;
        
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
    (my $colDebt    = firstidx {$_ eq 'Основной долг'        } @$header) >=0 or die "malformed csv";
    (my $colRevenue = firstidx {$_ eq 'Доход после удержания'} @$header) >=0 or die "malformed csv";
    (my $colSIR     = firstidx {$_ eq 'НПД'                  } @$header) >=0 or die "malformed csv";

     $colIn     -= scalar @$header;
     $colOut    -= scalar @$header;
     $colRevenue-= scalar @$header;
     $colSIR    -= scalar @$header;

    foreach my $line(@$csv)
    {
        my $event = { date => $line->[$colDate]};
        
        my $op = $line->[$colOp];
        if('Пополнение счета' eq $op || 'Вывод средств' eq $op)
        {
            $event->{deposit} += $line->[$colIn] - $line->[$colOut];
        }
        elsif('Платеж по займу' eq $op || 'Дефолт' eq $op || 'Зачисление по судебному взысканию' eq $op)
        {
            $event->{revenue_i} += $line->[$colRevenue];
        }
        elsif('Покупка займа на вторичном рынке' eq $op || 'Продажа займа на вторичном рынке' eq $op)
        {
            $event->{revenue_i} += $line->[$colSIR];
            $event->{revenue_s} += $line->[$colRevenue];
        }
        else
        {
            $event->{revenue_o} += $line->[$colRevenue];
        }

        $event->{assetChange} += $line->[$colDebt];
        $event->{assetChange} += $line->[$colRevenue] if 'Дефолт' eq $op;

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
        
        if('110' eq $rec->{event_type} || '120' eq $rec->{event_type})#Пополнение счета,Вывод со счета
        {
            $event->{deposit} += $rec->{income} - $rec->{expense};
        }
        elsif('310' eq $rec->{event_type} || '320' eq $rec->{event_type} || '220' eq $rec->{event_type})#Платеж по займу, Зачисление средств в рамках судебного взыскания, Дефолт
        {
            $event->{revenue_i} += $rec->{revenue} - $rec->{loss};
            $event->{assetChange} += $rec->{expense} - $rec->{income} + $rec->{revenue} - $rec->{loss} + $rec->{summary_interest_rate};
        }
        elsif('340' eq $rec->{event_type} || '342' eq $rec->{event_type} || '330' eq $rec->{event_type})#Покупка займа, Покупка по стратегии, Продажа займа
        {
            $event->{revenue_i} += $rec->{summary_interest_rate};
            $event->{revenue_s} += $rec->{revenue} - $rec->{loss};
            $event->{assetChange} += $rec->{expense} - $rec->{income} + $rec->{revenue} - $rec->{loss} + $rec->{summary_interest_rate};
        }
        elsif('210' eq $rec->{event_type})#Выдача займа
        {
            $event->{assetChange} += $rec->{expense} - $rec->{income} + $rec->{revenue} - $rec->{loss} + $rec->{summary_interest_rate};
        }
        else
        {
            $event->{revenue_o} += $rec->{revenue} - $rec->{loss};
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
        capital => 0,
        deposit => 0,
        asset => 0,
        assetChange => 0,
        revenue_i => 0,
        revenue_s => 0,
        revenue_o => 0,
    };
    @events = sort {$a->{date} cmp $b->{date}} @events;
    foreach my $event(@events)
    {
        my $nextDate = parseTs($event->{date});
        $nextDate -= $nextDate % (24*60*60);
        $state->{date} = $nextDate unless $state->{date};
        
        flushDay($state) while $state->{date} < $nextDate;
        
        $state->{deposit} += $event->{deposit};
        $state->{assetChange} += $event->{assetChange};
        $state->{revenue_i} += $event->{revenue_i};
        $state->{revenue_s} += $event->{revenue_s};
        $state->{revenue_o} += $event->{revenue_o};
    }

    flushDay($state);
    flushDay($state, 1);
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
sub isStateRegular($)
{
    my ($state) = @_;
    return
        $state->{capital} > 0 &&
        $state->{capital} + $state->{revenue_i} > 0 && 
        $state->{capital} + $state->{revenue_s} > 0 && 
        $state->{capital} + $state->{revenue_o} > 0 && 
        $state->{capital} + $state->{revenue_i} + $state->{revenue_s} + $state->{revenue_o} > 0;
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
            
            if($i >= $startIdx && isStateRegular($hrec))
            {
                state $log2 = log(2);
                my $value = log(($fetcher->($hrec) + $hrec->{capital}) / $hrec->{capital}) / $log2;
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
sub flushDay($;$)
{
    my ($state, $short) = @_;
    $short = 0 unless defined $short;
    
    push(@{history()}, {%{$state}});
    
    my $fetchers = 
    {
        _i => sub { return $_[0]->{revenue_i}; },
        _s => sub { return $_[0]->{revenue_s}; },
        _o => sub { return $_[0]->{revenue_o}; },
        ''  => sub { return $_[0]->{revenue_i} + $_[0]->{revenue_s} + $_[0]->{revenue_o}; },
    };
    
    my @fnames = ('', '_i', '_s', '_o');
    
    state $headerSayed = 0;
    if(!$headerSayed)
    {
        $headerSayed =1;
        print "date, deposit, capital, asset, irr";
        if(!$short)
        {
            print ", revenue$_, apy1$_, apy7$_, apy30$_, apy91$_, apy$_, cpy$_" foreach(@fnames);
        }
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
        $cashflow{dateTs($state->{date})} -= $state->{capital} + $state->{deposit} + $state->{revenue_i} + $state->{revenue_s} + $state->{revenue_o};
        #warn Dumper(\%cashflow);
        $irr = xirr(%cashflow, precision => 0.00001) if scalar keys %cashflow > 1;
    }

    print join(', ', 
        dateTs($state->{date}),
        $hideMoney ? -1 : sumStr($state->{deposit}, !1),
        $hideMoney ? -1 : sumStr($state->{capital}, !1),
        $hideMoney ? -1 : sumStr($state->{asset}, !1));

    if(!$short)
    {
        print ', ', rateStr($irr);

        foreach my $fname(@fnames)
        {
            my $fetcher = $fetchers->{$fname};

            my $apy1  = apy($fetcher, 1);
            my $apy7  = apy($fetcher, 7);
            my $apy30 = apy($fetcher, 30);
            my $apy91 = apy($fetcher, 91);
            my $apy = apy($fetcher);
            
            my $daysAvailable = scalar @{history()};
            my $cpy = $apy / daysInYear($state->{date}) * ($daysAvailable-1) if defined $apy && $daysAvailable-1 >= 1;

            print ', ', join(', ', 
                $hideMoney ? -1 : sumStr($fetcher->($state), !1),
                rateStr($apy1),
                rateStr($apy7),
                rateStr($apy30),
                rateStr($apy91),
                rateStr($apy),
                rateStr($cpy));
        }
    }
    print "\n";

    if(isStateRegular($state))
    {
        $state->{capital} += $state->{deposit} + $state->{revenue_i} + $state->{revenue_s} + $state->{revenue_o};
        $state->{deposit} = 0;
        $state->{revenue_i} = 0;
        $state->{revenue_s} = 0;
        $state->{revenue_o} = 0;
    }
    else
    {
        $state->{capital} += $state->{deposit};
        $state->{deposit} = 0;
    }
    
    $state->{asset} += $state->{assetChange};
    $state->{assetChange} = 0;

    $state->{date} += 24*60*60;
    
    $headerSayed = 1;
}
