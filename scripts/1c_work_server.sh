#!/bin/bash
#
# Мониторинг 1С Предприятия 8.3 (рабочий сервер)
#
#set -x

WORK_DIR=$(dirname "${0}" | sed -r 's/\\/\//g; s/^(.{1}):/\/\1/')

# Включить опцию extglob если отключена (используется в 1c_common_module.sh)
shopt -q extglob || shopt -s extglob

source "${WORK_DIR}/1c_common_module.sh" 2>/dev/null || {
	echo "ОШИБКА: Не найден файл 1c_common_module.sh!"
	exit 1
}

# Коды завершения процедуры архивирования файлов технологического журнала
export DUMP_CODE_0=0 # Архивированение файлов ТЖ выполнено успешно
export DUMP_CODE_1=1 # Файл архива ТЖ уже существует
export DUMP_CODE_2=2 # При архивировании файлов ТЖ возникли ошибки
export DUMP_CODE_3=3 # Не удалось выполнить архивирование ТЖ на удаленом сервере

function check_log_dir {
	[[ ! -d "${1}/zabbix/${2}" ]] && error "Неверно задан каталог технологического журнала!"
}

function check_measures_dir {
	[[ ! -d "${1}/" ]] && error "Неверно задан каталог замеров времени!"
	mkdir "${1}/inprocess" 2>/dev/null
	mkdir "${1}/processed" 2>/dev/null
}

function check_cache_dir {
    [[ -d "${1}" ]] || error "Неверно задан каталог хранения кэша данных кластера!"
}

function get_calls_info {

	MODE=${1}

	[[ -n ${2} ]] && TOP_LIMIT=${2} || TOP_LIMIT=25

	case ${MODE} in
	count) printf "%10s|%12s|%12s|%12s|%12s|%12s|%12s|%s\t%s\n" "Count" "Duration" "CPU" "AvgDuration" "AvgCPU" "PeakRAM" "RAM" "Context" ;;
	cpu) printf "%12s|%12s|%12s|%12s|%10s|%12s|%12s|%s\t%s\n" "CPU" "AvgCPU" "Duration" "AvgDuration" "Count" "PeakRAM" "RAM" "Context" ;;
	duration) printf "%12s|%12s|%12s|%12s|%10s|%12s|%12s|%s\n" "Duration" "AvgDuration" "CPU" "AvgCPU" "Count" "PeakRAM" "RAM" "Context" ;;
	lazy) printf "%12s|%12s|%12s|%12s|%10s|%12s|%12s|%s\t%s\n" "Dur/CPU" "AvgDur/AvgCPU" "Duration" "CPU" "Count" "PeakRAM" "RAM" "Context" ;;
	dur_avg) printf "%12s|%12s|%12s|%12s|%10s|%12s|%12s|%s\t%s\n" "AvgDuration" "Duration" "CPU" "AvgCPU" "Count" "PeakRAM" "RAM" "Context" ;;
	cpu_avg) printf "%12s|%12s|%12s|%12s|%10s|%12s|%12s|%s\t%s\n" "AvgCPU" "CPU" "AvgDuration" "Duration" "Count" "PeakRAM" "RAM" "Context" ;;
	memorypeak) printf "%12s|%12s|%12s|%12s|%12s|%12s|%10s|%s\t%s\n" "PeakRAM" "PeakSumRAM" "RAM" "AvgRAM" "Duration" "AvgDuration" "Count" "Context" ;;
	memory) printf "%12s|%12s|%12s|%12s|%12s|%12s|%10s|%s\t%s\n" "RAM" "AvgRAM" "PeakRAM" "AvgPeakRAM" "Duration" "AvgDuration" "Count" "Context" ;;
	iobytes) printf "%12s|%12s|%12s|%12s|%12s|%12s|%10s|%s\t%s\n" "SumIO" "AvgIO" "Input" "Output" "Duration" "AvgDuration" "Count" "Context" ;;
	*) error "${ERROR_UNKNOWN_PARAM}" ;;
	esac

	put_brack_line 150

	cat "${LOG_DIR}"/rphost_*/"${LOG_FILE}.log" 2>/dev/null | awk "/CALL,.*?(Context|Module|applicationName=Web)/" |
		perl -pe 's/\xef\xbb\xbf//g' |
		perl -pe 's/(\d{2}:\d{2})\.(\d{6})-(\d+)/$3/g' |
		# Серверные вызовы
		perl -pe 's/(.+?),CALL,.*?p:processName=(.+?),.*?Usr=(.+?),.*?Context=(.*?),.*?Memory=(.*?),.*?MemoryPeak=(.*?),.*?InBytes=(.*?),.*?OutBytes=(.*?),.*?CpuTime=(.*?)($|,.*$)/$1ϖServerCallϖ$2ϖ$3ϖ$4ϖ$5ϖ$6ϖ$7ϖ$8ϖ$9/' |
		# Регламентные задания
		perl -pe 's/(.+?),CALL,.*?Usr=(.+?),.*?p:processName=(.+?),.*?Module=(.+),Method=(.*?),.*?Memory=(.*?),.*?MemoryPeak=(.*?),.*?InBytes=(.*?),.*?OutBytes=(.*?),.*?CpuTime=(.*?)($|,.*$)/$1ϖBackgroundJobϖ$3ϖ$2ϖ$4.$5ϖ$6ϖ$7ϖ$8ϖ$9ϖ$10/' |
		# Веб-сервисы
		perl -pe 's/(.+?),CALL,.*?p:processName=(.+?),.*?=WebServerExtension.*?,Usr=(.+?),.*?Memory=(.*?),.*?MemoryPeak=(.*?),.*?InBytes=(.*?),.*?OutBytes=(.*?),.*?CpuTime=(.*?)($|,.*$)/$1ϖWebServerϖ$2ϖ$3ϖWebServerϖ$4ϖ$5ϖ$6ϖ$7ϖ$8/' |
		gawk -F'ϖ' -v mode="${MODE}" '\
		{CurDur=$1; Type=$2; Db=$3; Usr=$4; Cntx="Cntx="$5; \
		Group=Type ":" Db; \
		if (Type=="WebServer" || Type=="BackgroundJob") Group=Group ":" Usr; \
		CurMem=$6; CurMemPeak=$7; CurInBytes=$8; CurOutBytes=$9; CurCpuTime=$10; \
		Dur[Group][Cntx]+=CurDur; \
		CpuTime[Group][Cntx]+=CurCpuTime; \
		Mem[Group][Cntx]+=CurMem; \
		Execs[Group][Cntx]+=1; \
		Types[Group][Cntx]=Type;
		if (!MemPeak[Group][Cntx] || MemPeak[Group][Cntx] < CurMemPeak) MemPeak[Group][Cntx]=CurMemPeak; \
		if (mode == "iobytes") { \
			In[Group][Cntx]+=CurInBytes; \
			Out[Group][Cntx]+=CurOutBytes; \
		} \
		} END \
		{Koef=1000*1000; KoefMem=1024*1024; Summary=0; SummaryGroups["WebServer"]=0; SummaryGroups["ServerCall"]=0; SummaryGroups["BackgroundJob"]=0;\
		if (mode == "count") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					Summary+=cExecs; \
					SummaryGroups[Types[Group][Cntx]]+=cExecs;
					printf "%10d|%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%s\t%s\n", \
					cExecs, cDur, cCpuTime, cDur/cExecs, cCpuTime/cExecs, cMemP, cMem, Group, Cntx } } \
			printf "9999999999_%10d|\t%s; %d - %s; %d - %s; %d - %s\n", Summary, "!Общее количество операций", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "cpu") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					Summary+=cCpuTime; \
					SummaryGroups[Types[Group][Cntx]]+=cCpuTime;
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
					cCpuTime, cCpuTime/cExecs, cDur, cDur/cExecs, cExecs, cMemP, cMem, Group, Cntx } } \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общая нагрузка CPU", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "duration") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					Summary+=cDur; \
					SummaryGroups[Types[Group][Cntx]]+=cDur;
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
					cDur, cDur/cExecs, cCpuTime, cCpuTime/cExecs, cExecs, cMemP, cMem, Group, Cntx } } \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общая длительность операций", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "lazy") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					if (cCpuTime == 0) continue; \
					SummaryD+=cDur; SummaryC+=cCpuTime; \
					SummaryGroupsD[Types[Group][Cntx]]+=cDur; SummaryGroupsC[Types[Group][Cntx]]+=cCpuTime; \
					printf "%12.3f!|%12.3f|%12.3f|%12.3f|%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
					(cDur/cCpuTime)*cExecs, cDur/cCpuTime, (cDur/cCpuTime)/cExecs, cDur, cCpuTime, cExecs, cMemP, cMem, Group, Cntx } } \
			if (SummaryC > 0) Summary=SummaryD/SummaryC; for (Group in SummaryGroupsD) SummaryGroups[Group]=SummaryGroupsD[Group]/SummaryGroupsC[Group];  \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общее соотношение Duration/CPU", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "dur_avg") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					SummaryD+=cDur; SummaryE+=cExecs; \
					SummaryGroupsD[Types[Group][Cntx]]+=cDur; SummaryGroupsE[Types[Group][Cntx]]+=cExecs; \
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
					cDur/cExecs, cDur, cCpuTime, cCpuTime/cExecs, cExecs, cMemP, cMem, Group, Cntx } } \
			if (SummaryE > 0) Summary=SummaryD/SummaryE; for (Group in SummaryGroupsD) SummaryGroups[Group]=SummaryGroupsD[Group]/SummaryGroupsE[Group];  \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общее среднее время операций", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "cpu_avg") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					SummaryC+=cCpuTime; SummaryE+=cExecs; \
					SummaryGroupsC[Types[Group][Cntx]]+=cCpuTime; SummaryGroupsE[Types[Group][Cntx]]+=cExecs; \
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
					cCpuTime/cExecs, cCpuTime, cDur, cDur/cExecs, cExecs, cMemP, cMem, Group, Cntx } } \
			if (SummaryE > 0) Summary=SummaryC/SummaryE; for (Group in SummaryGroupsC) SummaryGroups[Group]=SummaryGroupsC[Group]/SummaryGroupsE[Group];  \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общая средняя нагрузка операций на CPU", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "memorypeak") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					if (Summary < cMemP) Summary=cMemP; \
					if (SummaryGroups[Types[Group][Cntx]] < cMemP) SummaryGroups[Types[Group][Cntx]]=cMemP; \
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%10d|%s\t%s\n", \
					cMemP, cMemP/cExecs, cMem, cMem/cExecs, cDur, cCpuTime, cExecs, Group, Cntx } } \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Максимальная потребленная память за вызов", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "memory") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					Summary+=cMem; \
					SummaryGroups[Types[Group][Cntx]]+=cMem;
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%10d|%s\t%s\n", \
					cMem, cMem/cExecs, cMemP, cMemP/cExecs, cDur, cCpuTime, cExecs, Group, Cntx } } \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общая не освобожденная память", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		else if (mode == "iobytes") { \
			for (Group in Dur) { \
				for (Cntx in Dur[Group]) { \
					cDur=Dur[Group][Cntx]/Koef; cExecs=Execs[Group][Cntx]; cCpuTime=CpuTime[Group][Cntx]/Koef; cMemP=MemPeak[Group][Cntx]/KoefMem; cMem=Mem[Group][Cntx]/KoefMem; \
					cIn=In[Group][Cntx]/KoefMem; cOut=Out[Group][Cntx]/KoefMem; \
					Summary+=(cIn+cOut); \
					SummaryGroups[Types[Group][Cntx]]+=(cIn+cOut);
					printf "%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%12.3f|%10d|%s\t%s\n", \
					cIn+cOut, (cIn+cOut)/cExecs, cIn, cOut, cDur, cCpuTime, cExecs, Group, Cntx } } \
			printf "9999999999_%12.3f|\t%s; %.3f - %s; %.3f - %s; %.3f - %s\n", Summary, "!Общая сумма ввода-вывода", SummaryGroups["ServerCall"], "ServerCall", SummaryGroups["WebServer"], "WebServer", SummaryGroups["BackgroundJob"], "BackgroundJob"; \
		} \
		}' |
		sort -rn | head -n "${TOP_LIMIT}" | perl -pe 's/9999999999_//; s/.+?!\|//'

}

function get_measures_info {

    [[ -n ${1} ]] && TOP_LIMIT=${1} || TOP_LIMIT=25

    [[ -n ${2} ]] && APDEX_LIST=${2//,/|} || APDEX_LIST="\"?.*"

    ls ${LOG_DIR}/*.xml >/dev/null 2>&1 || error "Нет файлов для обработки"

    FILE_MASK=$(find "${LOG_DIR}"/*.xml -maxdepth 1 -type f -print | tail -n 1 | sed -r "s/.*?([0-9\-]{10}\s[0-9\-]{8}).*\.xml/\1/" 2>/dev/null)

    printf "%5s|%10s|%10s|%10s|%s\n" "Apdex" "Avg" "Target" "Count" "Operation"

    put_brack_line

    RESULT=$(grep -h "" "${LOG_DIR}"/"${FILE_MASK}"*.xml 2>/dev/null | \
        perl -pe 's/\xef\xbb\xbf//g' | \
        sed '/<\/prf/d;/<\?xml/d;/<prf:Performance/d' | \
        perl -pe 's/\n/@@/g; s/<prf:KeyOperation/\n<prf:KeyOperation/g' | \
        awk '/<prf:KeyOperation.*?nameFull=".*?('${APDEX_LIST}')/' | \
        perl -pe 's/@@.*?measurement value=\"(.+?)\".*?weight=\"(.+?)\".*?\/>/$1_$2;/g' | \
        perl -pe 's/.*?targetValue=\"(.+?)\".*?nameFull=\"(.+?)\".*?>/$1ϖ$2ϖ/g' | \
        perl -pe 's/@@//g' | \
		gawk -F'ϖ' '\
            {target=$1; oper=$2; \
            operVal[oper]["target"]=target; \
            split($3, values, ";"); \
            target4=target*4; \
            sum=0; \
            count=0; \
            countT=0; \
            count4T=0; \
            for (value in values) { \
                split(values[value], curValueWeight, "_"); \
				if (!curValueWeight[1]) continue; \
				curWeight = curValueWeight[2]; \
				if (!curWeight||curWeight==0) curWeight=1; \
				curValue=curValueWeight[1]/curWeight; \
                sum+=curValue; \
                count++; \
                if (curValue<target) countT++; \
                else if (curValue<target4) count4T++; \
            } \
            operVal[oper]["value"]+=sum; \
            operVal[oper]["count"]+=count; \
            operVal[oper]["countT"]+=countT; \
            operVal[oper]["count4T"]+=count4T; \
            } END { \
            count=0; \
            countT=0; \
            count4T=0; \
			for (oper in operVal) {\
                count+=operVal[oper]["count"]; \
                countT+=operVal[oper]["countT"]; \
                count4T+=operVal[oper]["count4T"]; \
				apdex = (operVal[oper]["countT"] + operVal[oper]["count4T"]/2)/operVal[oper]["count"]; \
                printf "%10.2f!|%5.2f|%10.3f|%10.2f|%10d|%s\n", \
                    (1-apdex)*operVal[oper]["count"], \
					apdex, \
                    operVal[oper]["value"]/operVal[oper]["count"], \
                    operVal[oper]["target"], \
                    operVal[oper]["count"], \
                    oper \
            } \
            summaryApdex = 1;
            if (count > 0) summaryApdex=(countT+count4T/2)/count;
            printf "9999999999_%s%.2f|%s; %d - %s\n", "!",summaryApdex, "Общий APDEX", count, "Всего операций" \
            }' |
		sort -rn | head -n "${TOP_LIMIT}" | perl -pe 's/9999999999_//; s/.+?!\|//')
    echo "${RESULT}"
    
}

function get_db_info {

	MODE=${1}

	case ${MODE} in
	list)
		shift 1
		get_db_list_info "${@}"
		;;
	*) get_db_summary_info "${@}" ;;
	esac

}

function get_db_summary_info {

	printf "%12s|%10s|%12s|%12s|%s\n" "Duration" "Count" "AvgDuration" "MaxDuration" "Context"

	put_brack_line

	cat "${LOG_DIR}"/rphost_*/"${LOG_FILE}.log" 2>/dev/null |
		perl -pe 's/\xef\xbb\xbf//g' |
		perl -pe 's/\d{2}:\d{2}\.\d{6}-(\d+).*?,p:processName=(.+?)($|,.*$)/$1ϖ$2/' |
		gawk -F'ϖ' '\
	{CurDur=$1; Db=$2; \
	Group=Db; \
	Dur[Group]+=CurDur; \
	Execs[Group]+=1; \
	{Koef=1000 * 1000; \
	for (Group in Dur) \
		printf "%12.3f|%10d|%12.3f|%12.3f|%s\n", \
			Dur[Group]/Koef, \
			Execs[Group], \
			(Dur[Group]/Koef)/Execs[Group], \
			Max[Group]/Koef, \
			Group}' |
		sort -rn |
		head -n "${TOP_LIMIT}"

}

function get_db_list_info {

	[[ -n ${1} ]] && TOP_LIMIT=${1} || TOP_LIMIT=25

	printf "%12s|%10s|%12s|%12s|%s\n" "Duration" "Count" "AvgDuration" "MaxDuration" "Context"

	put_brack_line

	cat "${LOG_DIR}"/rphost_*/"${LOG_FILE}.log" 2>/dev/null |
		perl -pe 's/\xef\xbb\xbf//g' |
		perl -pe 's/[\r\n]+/@@/g; s/\d{2}:\d{2}\.\d{6}-/\n/g' |
		awk '/,(DBPOSTGRS|DBMSSQL),/' |
		perl -pe 's/(\d+).*?,p:processName=(.+?),.*?Context=(.+)($|,.*$)/$1ϖ$2ϖ$3/' |
		gawk -F'ϖ' '\
	{CurDur=$1; Db=$2; Cntx=$3; \
	Group=Db; \
	countCntx = split($3, valuesCntx, "@@"); \
	if (countCntx > 0) \
		if (countCntx == 1) Cntx = valuesCntx[countCntx - 1]; \
		else Cntx = valuesCntx[countCntx - 2] " --> " valuesCntx[countCntx - 1]; \
	gsub("(\\s{2,}|\\r)", "", Cntx); \
	Dur[Group][Cntx]+=CurDur; \
	Execs[Group][Cntx]+=1; \
	if(!Max[Group][Cntx]||Max[Group][Cntx]<CurDur*1) Max[Group][Cntx]=CurDur*1} END \
	{Koef=1000 * 1000; \
	for (Group in Dur) \
		for (Cntx in Dur[Group]) \
		printf "%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
			Dur[Group][Cntx]/Koef, \
			Execs[Group][Cntx], \
			(Dur[Group][Cntx]/Koef)/Execs[Group][Cntx], \
			Max[Group][Cntx]/Koef, \
			Group, Cntx}' |
		sort -rn |
		head -n "${TOP_LIMIT}" |
		perl -pe 's/@@/\n/g'

}

function get_locks_info {

	MODE=${4}

	case ${MODE} in
	list)
		shift 4
		get_locks_list_info "${@}"
		;;
	*) get_locks_summary_info "${@}" ;;
	esac

}

function get_locks_summary_info {

	STORE_PERIOD=30 # Срок хранения архивов ТЖ, содержащих информацию о проблемах - 30 дней

	WAIT_LIMIT=${1}

	function save_logs {
		if [[ $(echo "${1}" | grep -ic "${HOSTNAME}") -ne 0 ]]; then
			DUMP_RESULT=$(dump_logs "${LOG_DIR}" "${LOG_FILE}")
		else
			DUMP_RESULT=$(zabbix_get -s "${1}" -k 1c.ws.dump_logs["${LOG_DIR}","${LOG_FILE}"] 2>/dev/null)
			[[ -z ${DUMP_RESULT} || ${DUMP_RESULT} -eq ${DUMP_CODE_2} ]] && DUMP_RESULT=${DUMP_CODE_3}
		fi

		[[ ${DUMP_RESULT} -gt 1 ]] && DUMP_TEXT="ОШИБКА: не удалось сохранить файлы технологического журнала!" ||
			DUMP_TEXT="Файлы технологического журнала сохранены (${LOG_DIR%/*}/problem_log/${LOG_DIR##*/}-${LOG_FILE}.tgz)"

		[[ -n ${DUMP_RESULT} ]] && echo "[${1} (${DUMP_RESULT})] ${DUMP_TEXT}" && unset DUMP_RESULT
	}

	echo "lock: $(cat "${LOG_DIR}"/rphost_*/"${LOG_FILE}.log" 2>/dev/null | grep -c ',TLOCK,')"

	RESULT=$(cat "${LOG_DIR}"/rphost_*/"${LOG_FILE}.log" 2>/dev/null |
		awk "/(TDEADLOCK|TTIMEOUT|TLOCK).*,WaitConnections='?[0-9,]+'?/" |
		sed -re "s/[0-9]{2}:[0-9]{2}.[0-9]{6}-//; s/,[a-zA-Z\:]+=/,/g" |
		awk -F"," -v lts="${WAIT_LIMIT}" 'BEGIN {dl=0; to=0; lw=0} { if ($2 == "TDEADLOCK") {dl+=1} \
            else if ($2 == "TTIMEOUT") { to+=1 } \
            else { lw+=$1; lws[$4"->"$6]+=$1; } } \
            END { print "timeout: "to"<nl>"; print "deadlock: "dl"<nl>"; print "wait: "lw/1000000"<nl>"; \
            if ( lw > 0 ) { print "Ожидания на блокировках (установлен порог "lts" сек):<nl>"; \
            for ( i in lws ) { print "> "i" - "lws[i]/1000000" сек.<nl>" } } }')

	echo "${RESULT[@]}" | perl -pe 's/<nl>\s?/\n/g'

	if [[ "${RESULT[1]%<*}" != 0 || "${RESULT[3]%<*}" != 0 ||
		$(awk -v value="${RESULT[5]%<*}" -v limit="${WAIT_LIMIT}" 'BEGIN { print ( value > limit ) }') == 1 ]]; then

		shift
		make_ras_params "${@}"

		check_clusters_cache

		for CURRENT_HOST in $(pop_clusters_list); do
			CLSTR_LIST=${CURRENT_HOST#*#}
			for CURR_CLSTR in ${CLSTR_LIST//;/ }; do
				SRV_LIST+=($(timeout -s HUP "${RAS_TIMEOUT}" rac server list --cluster="${CURR_CLSTR%,*}" \
					${RAS_AUTH} "${CURRENT_HOST%#*}" 2>/dev/null | grep agent-host | sort -u |
					sed -r "s/.*: (.*)$/\1/; s/\"//g"))
			done
		done

	fi

	export -f dump_logs
	execute_tasks save_logs $(echo "${SRV_LIST[@]}" | perl -pe 's/ /\n/g' | sort -u)

	find "${LOG_DIR%/*}/problem_log/" -mtime +${STORE_PERIOD} -name "*.tgz" -delete 2>/dev/null
}

function get_locks_list_info {

	[[ -n ${1} ]] && TOP_LIMIT=${1} || TOP_LIMIT=25

	printf "%12s|%10s|%12s|%12s|%s\n" "DurationWC" "Count" "AvgDuration" "Max" "Context"

	cat "${LOG_DIR}"/rphost_*/"${LOG_FILE}.log" 2>/dev/null |
		perl -pe 's/\xef\xbb\xbf//g' |
		perl -pe 's/[\r\n]+/@@/g; s/\d{2}:\d{2}\.\d{6}-/\n/g' |
		awk '/,TLOCK,.+Context=.+/' |
		perl -pe "s/(\d+),(\w+),.*?p:processName=(.+?),.*?WaitConnections=('?[0-9,]*'?),.*Context=(.+)($|,.*$)/\1ϖ\2ϖ\3ϖ\4ϖ\5/" |
		gawk -F'ϖ' '\
		{CurDur=$1; Event=$2; Db=$3; WaitConn=$4; Cntx=$5; \
		Group=Event "\t" Db; \
		Dur[Group][Cntx]+=CurDur; \
		Execs[Group][Cntx]+=1; \
		if (WaitConn!="") { DurWC[Group][Cntx]+=CurDur; DurWCSum+=CurDur; } \
		if(!Max[Group][Cntx]||Max[Group][Cntx]<CurDur*1) Max[Group][Cntx]=CurDur*1} END \
		{Koef=1000 * 1000; \
		for (Group in Dur) \
			for (Cntx in Dur[Group]) \
			printf "%12.3f|%10d|%12.3f|%12.3f|%s\t%s\n", \
				DurWC[Group][Cntx]/Koef, \
				Execs[Group][Cntx], \
				(Dur[Group][Cntx]/Koef)/Execs[Group][Cntx], \
				Max[Group][Cntx]/Koef, \
				Group, Cntx; \
		printf "9999999999_%12.3f - %s\n", DurWCSum/Koef, "!Общее время ожидания блокировок"; \
		}' |
		sort -rn |
		head -n "${TOP_LIMIT}" | perl -pe 's/9999999999_//' |
		perl -pe 's/@@/\n/g'

}

function get_excps_info {

	MODE=${1}

	case ${MODE} in
	list)
		shift 1
		get_excps_list_info "${@}"
		;;
	*) get_excps_summary_info "${@}" ;;
	esac

}

function get_excps_summary_info {

	for PROCESS in "${PROCESS_NAMES[@]}"; do
		EXCP_COUNT=$(cat "${LOG_DIR}"/"${PROCESS}"_*/"${LOG_FILE}.log" 2>/dev/null | grep -c ",EXCP,")
		echo "${PROCESS}: $([[ -n ${EXCP_COUNT} ]] && echo "${EXCP_COUNT}" || echo 0)"
	done

}

function get_excps_list_info {

	[[ -n ${1} ]] && TOP_LIMIT=${1} || TOP_LIMIT=25

	grep -H "" "${LOG_DIR}"/*/"${LOG_FILE}.log" 2>/dev/null |
		perl -pe 's/\xef\xbb\xbf//g' |
		perl -pe 's/^.*\d{8}\.log:$//g' |
		awk "/^.*[0-9]{8}\.log:/" |
		perl -pe 's/^.*[\/\\](.*?_\d+)[\/\\]\d{8}\.log:(\d{2}:\d{2})\.(\d{6})-(\d+)/\1,\4/g' |
		perl -pe 's/^.*\d{8}\.log://g' |
		perl -pe 's/[\r\n]+/@@/g; s/(.+?_\d+)/\n\1/g' |
		awk '/,EXCP,.+Descr=.+/' |
		perl -pe 's/(.+?)_(.+?),.*?Descr=(.*?)($|,.*$)/\1ϖ\2ϖ\3/' |
		gawk -F'ϖ' '\
		{Proc=$1; ProcID=$2; Descr=$3; \
		Group=Proc "\t" Descr; \
		Execs[Group]+=1; } END \
		{for (Group in Execs) \
			printf "%d\t%s\n", Execs[Group], Group}' |
		sort -rn |
		head -n "${TOP_LIMIT}" |
		perl -pe 's/@@/\n\t/g'

}

function get_cluster_events_info {

	[[ -n ${1} ]] && TOP_LIMIT=${1} || TOP_LIMIT=25

	grep -H "" "${LOG_DIR}"/*/"${LOG_FILE}.log" 2>/dev/null |
		perl -pe 's/\xef\xbb\xbf//g' |
		perl -pe 's/^.*\d{8}\.log:$//g' |
		awk "/^.*[0-9]{8}\.log:/" |
		perl -pe 's/^.*[\/\\](.*?_\d+)[\/\\]\d{8}\.log:(\d{2}:\d{2})\.(\d{6})-(\d+)/\1,\4/g' |
		perl -pe 's/^.*\d{8}\.log://g' |
		perl -pe 's/[\r\n]+/@@/g; s/(.+?_\d+)/\n\1/g' |
		awk '/,Descr=.+/' |
		perl -pe 's/(.+?)_\d+?,\d+,(\w+),.*?Descr=(.*?)($|,.*$)/\1ϖ\2ϖ\3/' |
		gawk -F'ϖ' '\
		{Proc=$1; Event=$2; Descr=$3; \
		Group=Proc "\\" Event "\t" Descr; \
		Execs[Group]+=1; } END \
		{for (Group in Execs) \
			printf "%d\t%s\n", Execs[Group], Group}' |
		sort -rn |
		head -n "${TOP_LIMIT}" |
		perl -pe 's/@@/\n\t/g'

}

function get_memory_counts {

	RPHOST_PID_HASH="${TMPDIR}/1c_rphost_pid_hash"

	if [[ -z "${IS_WINDOWS}" ]]; then
		ps -hwwp "$(pgrep -d, 'ragent|rphost|rmngr|postgres|sqlservr')" -o comm,pid,rss,vsz,cmd -k pid |
			sed -re 's/^([^ ]+) +([0-9]+) +([0-9]+) +([0-9]+) +/\1,\2,\3,\4,/'
	else
		wmic path win32_process where "caption like 'ragent%' or caption like 'rmngr%' or caption like 'rphost%' or caption like 'rphost%' or caption like 'sqlservr%' or caption like 'postgres%'" \
			get caption,processid,virtualsize,workingsetsize,commandline /format:csv |
			sed -re 's/^[^,]+,([^,]+),([^,]+),([^,]+),([^,]+),(.*)/\1,\3,\5,\4,\2/'
	fi | awk -F, -v mem_in_kb="${IS_WINDOWS:-1024}" -v pid_hash="$(cat "${RPHOST_PID_HASH}" 2>/dev/null)" \
		'/.*,[0-9]+,[0-9]+/ {
            proc_name[$1]=gensub(/[.].+/,"","g",$1)
            proc_pids[$1][$2]
            proc[$1,"memory"]+=$3
			proc[$1,"vmemory"]+=$4
            } END {
                for ( pn in proc_name ) { 
                    proc_flag=""; pid_list=""
                    switch (pn) {
                        case /ragent.*/:
                            if ($4 ~ /(\/|-)debug(\s|$)/ ) proc_flag=1; else proc_flag=0
                            break
                        case /rphost.*/:
                            for (i in proc_pids[pn]) pid_list=pid_list?pid_list","i:i
                            hash_command="echo "pid_list" | md5sum | sed \"s/ .*//\""
                            (hash_command | getline new_hash) > 0
                            close(hash_command)
                            if ( pid_hash == new_hash ) { proc_flag=0 } else { proc_flag=1 }
                            print new_hash > "'"${RPHOST_PID_HASH}"'"
                            break
                    }
                    print proc_name[pn]":",length(proc_pids[pn]),proc[pn,"memory"]*mem_in_kb,proc[pn,"vmemory"]*mem_in_kb,proc_flag
                }
            }'

}

function get_cpu_memory_list {

	MODE=${1}

	case ${MODE} in
	mem) printf "%15s|%15s|%15s|%10s|%s\n" "Working Set" "Virtual Bytes" "Private Bytes" "CPU" "Name" ;;
	cpu) printf "%10s|%15s|%15s|%15s|%s\n" "CPU" "Working Set" "Virtual Bytes" "Private Bytes" "Name" ;;
	*) error "${ERROR_UNKNOWN_PARAM}" ;;
	esac

	if [[ -z "${IS_WINDOWS}" ]]; then
		ps -hwwp "$(pgrep -d, '')" -o comm,pid,rss,vsz,pcpu,cmd -k pid |
			perl -pe 's/^([^ ]+) +(\d*) +(\d*) +(\d*) +(\d*\.?\d*).*/\1,\2,\3,\4,\3,\5/'
	else
		wmic path Win32_PerfFormattedData_PerfProc_Process \
			get IDProcess,Name,PercentProcessorTime,PrivateBytes,VirtualBytes,WorkingSet /format:csv |
			perl -pe 's/^.+?,(.+?),(.+?),(\d*),(\d*),(\d*),(\d*)/\2,\1,\6,\5,\4,\3/'
	fi |
		awk -F, -v mode="${MODE}" -v mem_in_kb="${IS_WINDOWS:-1024}" \
			'/.*,[0-9]+,[0-9]+,[0-9]+/ {
			name=gensub(/[.#].+/,"","g",$1);
			procPids[name][$2];
			proc[name]["wmemory"]+=$3;
			proc[name]["vmemory"]+=$4;
			proc[name]["pmemory"]+=$5;
			proc[name]["cpu"]+=$6;
			} END {
				total["[DBMS]"]["wmemory"]=0; total["[DBMS]"]["vmemory"]=0; total["[DBMS]"]["pmemory"]=0; total["[DBMS]"]["cpu"]=0;
				total["[1C Cluster]"]["wmemory"]=0; total["[1C Cluster]"]["vmemory"]=0; total["[1C Cluster]"]["pmemory"]=0; total["[1C Cluster]"]["cpu"]=0;
				total["[TOTAL]"]["wmemory"]=0; total["[TOTAL]"]["vmemory"]=0; total["[TOTAL]"]["pmemory"]=0; total["[TOTAL]"]["cpu"]=0;
				KoefMem=1024*1024/mem_in_kb;
				if (mode=="mem") formatString = "%15d|%15d|%15d|%10d|%s\n";
				else if (mode=="cpu") formatString = "%10d|%15d|%15d|%15d|%s\n";
				for (pn in proc) {
					totalName=null;
					switch (pn) {
						case /postgres.*/:
						case /sqlservr.*/: {
							totalName="[DBMS]";
							break;
						}
						case /rphost.*/:
						case /ragent.*/:
						case /rmngr.*/: 
						case /dbda.*/:
						case /dbgs.*/: {
							totalName="[1C Cluster]";
							break;
						}
						case /_Total.*/:{
							continue;
							}
					}
					if (totalName!=null) {
						total[totalName]["wmemory"]+=proc[pn]["wmemory"]; total[totalName]["vmemory"]+=proc[pn]["vmemory"]; total[totalName]["pmemory"]+=proc[pn]["pmemory"]; total[totalName]["cpu"]+=proc[pn]["cpu"];
					}
					total["[TOTAL]"]["wmemory"]+=proc[pn]["wmemory"]; total["[TOTAL]"]["vmemory"]+=proc[pn]["vmemory"]; total["[TOTAL]"]["pmemory"]+=proc[pn]["pmemory"]; total["[TOTAL]"]["cpu"]+=proc[pn]["cpu"];
					
					wmemory=proc[pn]["wmemory"]/KoefMem; vmemory=proc[pn]["vmemory"]/KoefMem; pmemory=proc[pn]["pmemory"]/KoefMem; cpu=proc[pn]["cpu"];
					
					name=pn;
					if (length(procPids[pn]) > 1) name=pn":"length(procPids[pn]);
					
					if (mode == "mem") printf formatString, wmemory, vmemory, pmemory, cpu, name;
					else if (mode == "cpu") printf formatString, cpu, wmemory, vmemory, pmemory, name;
				}
				for (pn in total) {
					printf "999999999999999";
					if (mode == "mem") {
						printf formatString,
							total[pn]["wmemory"]*mem_in_kb, total[pn]["vmemory"]*mem_in_kb, total[pn]["pmemory"]*mem_in_kb, total[pn]["cpu"], pn;
					}
					else if (mode == "cpu") {
						printf formatString,
							total[pn]["cpu"], total[pn]["wmemory"]*mem_in_kb, total[pn]["vmemory"]*mem_in_kb, total[pn]["pmemory"]*mem_in_kb, pn;
					}
				}
			}' |
		sort -rn | head -n 15 | perl -pe 's/999999999999999//'
}

# Архивирование файлов ТЖ с именем ${2} из каталога ${1} в problem_log
function dump_logs {
	# TODO: Проверка наличия каталога problem_log и возможности записи в него

	if [[ -f ${1%/*}/problem_log/${1##*/}-${2}.tgz ]]; then
		DUMP_RESULT=${DUMP_CODE_1}
	else
		cd "${1}" 2>/dev/null && tar czf "../problem_log/${1##*/}-${2}.tgz" ./rphost_*/"${2}".log &&
			DUMP_RESULT=${DUMP_CODE_0} || DUMP_RESULT=${DUMP_CODE_2}
	fi

	echo "${DUMP_RESULT}"

}

function get_physical_memory {
	if [[ -z ${IS_WINDOWS} ]]; then
		free -b | grep -m1 "^[^ ]" | awk '{ print $2 }'
	else
		wmic computersystem get totalphysicalmemory | awk "/^[0-9]/"
	fi
}

function get_available_perfomance {

	check_clusters_cache

	(execute_tasks get_processes_perfomance $(pop_clusters_list)) | grep -i "${HOSTNAME}" |
		awk -F: '{ apc+=1; aps+=$2 } END { if ( apc > 0) { print aps/apc } else { print "0" } }'

}

case ${1} in
    calls | locks | excps | cluster) check_log_dir "${2}" "${1}";
        export LOG_FILE=$(date --date="last hour" "+%y%m%d%H");
        export LOG_DIR="${2%/}/zabbix/${1}" ;;&
	perfomance) check_cache_dir "${2}";
        export CLSTR_CACHE_DIR="${2}";
		export CLSTR_CACHE="${CLSTR_CACHE_DIR}/1c_clusters_cache";
		export IB_CACHE="${CLSTR_CACHE_DIR}/1c_infobase_cache";;&
    excps) PROCESS_NAMES=(ragent rmngr rphost) ;;&
    calls) shift 2; get_calls_info "${@}" ;;
    measures) check_measures_dir "${2}";
		export LOG_DIR="${2%/}" ;;&
	measures) shift 2; get_measures_info "${@}" ;;
	db_summary) check_log_dir "${2}" "${1}";
        export LOG_FILE=$(date --date="last hour" "+%y%m%d%H");
        export LOG_DIR="${2%/}/zabbix/${1}" ;;&
    db_summary) shift 2; get_db_info_summary "${@}" ;;
	db) check_log_dir "${2}" "${1}";
        export LOG_FILE=$(date --date="last hour" "+%y%m%d%H");
        export LOG_DIR="${2%/}/zabbix/${1}" ;;&
    db) shift 2; get_db_info "${@}" ;;
	locks) shift 2; get_locks_info "${@}" ;;
    excps) shift 2; get_excps_info "${@}" ;;
	cluster) shift 2; get_cluster_events_info "${@}" ;;
	memory) get_memory_counts ;;
	cpu_memory_list) shift; get_cpu_memory_list "${@}";;
    ram) get_physical_memory ;;
    dump_logs) shift; dump_logs "${@}" ;;
    perfomance) shift 2; make_ras_params "${@}"; get_available_perfomance ;;
    *) error "${ERROR_UNKNOWN_MODE}" ;;
esac
