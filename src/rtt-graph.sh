#!/bin/bash --norc
#
# Copyright 2017 Sandro Marcell <smarcell@mail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
PATH='/bin:/sbin:/usr/bin:/usr/sbin'

# Diretorio onde serao armazenadas as bases de dados do rrdtool
BASES_RRD='/var/db/rrdtool/rtt-graph'

# Diretorio no servidor web onde serao armazenados os arquivos html/png gerados
DIR_WWW='/var/www/lighttpd/rtt-graph'

# Gerar os graficos para os seguintes periodos de tempo
PERIODOS='day week month year'

# Intervalo de atualizacao das bases RRD (padrao 15 minutos)
# Obs.: altere esse valor somente se souber realmente o que esta fazendo!
INTERVALO=$((60 * 15))

#########################################################################
# Vetor com as definicoes dos equipamentos e seus respectivos ip's      #
#                                                                       #
# ATENCAO: ao adicionar novas entradas, SEMPRE MANTENHA a correta ordem #
# e sequencia dos indices deste vetor!                                  #
#########################################################################
declare -a HOSTS
# Modem
HOSTS[0]='CPE Allfiber'
HOSTS[1]='192.168.1.1'
# Roteador 1
HOSTS[2]='Roteador OpenWrt'
HOSTS[3]='10.11.12.1'
# Roteador 2
HOSTS[4]='Roteador OpenWrt-Rpt'
HOSTS[5]='10.11.12.2'

# Criando os diretorios de trabalho caso nao existam
[ ! -d "$BASES_RRD" ] && { mkdir -p "$BASES_RRD" || exit 1; }
[ ! -d "$DIR_WWW" ] && { mkdir -p "$DIR_WWW" || exit 1; }

gerarGraficos() {
	declare -a args=("${HOSTS[@]}")
	declare -a latencia
	declare host=''
	declare ip=''
	declare retorno_ping=0
	declare pp=0
	declare rtt_min=0
	declare rtt_med=0
	declare rtt_max=0

	while [ ${#args[@]} -ne 0 ]; do
		host="${args[0]}" # Nome do equipamento
		ip="${args[1]}" # IP do equipamento
		args=("${args[@]:2}") # Descartando os dois elementos ja lidos anteriormente do vetor

		retorno_ping=$(ping -qnU -i 0.2 -c 10 -W 1 $ip)
		# Pingou ou nao pingou?! :)
		[ $? -ne 0 ] && latencia=(0 0 0) || latencia=($(echo $retorno_ping | awk -F '/' 'END { print $4,$5,$6 }' | grep -oP '\d.+'))
		# Pacotes perdidos
		pp=$(echo $retorno_ping | grep -oP '\d+(?=% packet loss)')

		# Latencias minimas, medias e maximas
		rtt_min="${latencia[0]}"
		rtt_med="${latencia[1]}"
		rtt_max="${latencia[2]}"

		# Caso as bases rrd nao existam, entao serao criadas e cada uma
		# tera o mesmo nome do ip verificado
		if [ ! -e "${BASES_RRD}/${ip}.rrd" ]; then
			# Resolucao = Quantidade de segundos do periodo / (Intervalo de resolucao * Fator de multiplicacao de resolucao)
			v1hr=$((604800 / (INTERVALO * 4))) # Valor de 1 semana (1 hora de resolucao)
			v6hrs=$((2629800 / (INTERVALO * 24))) # Valor de 1 mes (6 horas de resolucao)
			v24hrs=$((31557600 / (INTERVALO * 288))) # Valor de 1 ano (24 horas de resolucao)

			echo "Criando base de dados rrd: ${BASES_RRD}/${ip}.rrd"
			rrdtool create ${BASES_RRD}/${ip}.rrd --start $(date '+%s') --step $INTERVALO \
				DS:min:GAUGE:$((INTERVALO * 2)):0:U \
				DS:med:GAUGE:$((INTERVALO * 2)):0:U \
				DS:max:GAUGE:$((INTERVALO * 2)):0:U \
				DS:pp:GAUGE:$((INTERVALO * 2)):0:U \
				RRA:MIN:0.5:3:288 \
				RRA:MIN:0.5:4:$v1hr \
				RRA:MIN:0.5:24:$v6hrs \
				RRA:MIN:0.5:288:$v24hrs \
				RRA:AVERAGE:0.5:3:288 \
				RRA:AVERAGE:0.5:4:$v1hr \
				RRA:AVERAGE:0.5:24:$v6hrs \
				RRA:AVERAGE:0.5:288:$v24hrs \
				RRA:MAX:0.5:3:288 \
				RRA:MAX:0.5:4:$v1hr \
				RRA:MAX:0.5:24:$v6hrs \
				RRA:MAX:0.5:288:$v24hrs
			[ $? -gt 0 ] && return 1
		fi

		# Se as bases ja existirem, entao atualize-as...
		echo "Atualizando base de dados: ${BASES_RRD}/${ip}.rrd"
		rrdtool update ${BASES_RRD}/${ip}.rrd --template pp:min:med:max N:${pp}:${rtt_min}:${rtt_med}:$rtt_max
		[ $? -gt 0 ] && return 1

		# e depois gere os graficos de acordo com os periodos
		for i in $PERIODOS; do
			case $i in
				  'day') tipo='Gráfico diário (amostragem de 15 min)'; p='1day' ;;
				 'week') tipo='Gráfico semanal (amostragem de 1h)'; p='7days' ;;
				'month') tipo='Gráfico mensal (amostragem de 6h)'; p='1month' ;;
				 'year') tipo='Gráfico anual (amostragem de 24h)'; p='1year' ;;
			esac

			rrdtool graph ${DIR_WWW}/${ip}-${i}.png --end now --start end-$p --lazy --font 'TITLE:0:Bold' --title "$tipo" \
				--watermark "$(date '+%^c')" --vertical-label 'Latência (ms)' --height 124 --width 550 \
				--lower-limit 0 --units-exponent 0 --slope-mode --imgformat PNG --rigid --alt-y-grid --interlaced \
				--color 'BACK#F8F8FF' --color 'SHADEA#FFFFFF' --color 'SHADEB#FFFFFF' \
				--color 'MGRID#AAAAAA' --color 'GRID#CCCCCC' --color 'ARROW#333333' \
				--color 'FONT#333333' --color 'AXIS#333333' --color 'FRAME#333333' \
				DEF:rtt_min=${BASES_RRD}/${ip}.rrd:min:MIN \
				DEF:rtt_med=${BASES_RRD}/${ip}.rrd:med:AVERAGE \
				DEF:rtt_max=${BASES_RRD}/${ip}.rrd:max:MAX \
				DEF:rtt_pp=${BASES_RRD}/${ip}.rrd:pp:MAX \
				VDEF:vmin=rtt_min,MINIMUM \
				VDEF:vmed=rtt_med,AVERAGE \
				VDEF:vmax=rtt_max,MAXIMUM \
				VDEF:vpp=rtt_pp,MAXIMUM \
				"COMMENT:$(printf '%5s')" \
				"LINE1:rtt_min#009900:Miníma\:$(printf '%11s')" \
				GPRINT:vmin:"%1.3lfms\l" \
				"COMMENT:$(printf '%5s')" \
				"LINE1:rtt_max#990000:Máxima\:$(printf '%11s')" \
				GPRINT:vmax:"%1.3lfms\l" \
				"COMMENT:$(printf '%5s')" \
				"LINE1:rtt_med#0066CC:Média\:$(printf '%12s')" \
				GPRINT:vmed:"%1.3lfms\l" \
				"COMMENT:$(printf '%5s')" \
				"COMMENT:Pacotes perdidos\:$(printf '%3s')" \
				GPRINT:vpp:"%1.0lf%%\l" 1> /dev/null
			[ $? -gt 0 ] && return 1
		done
	done
	return 0
}

criarPaginasHTML() {
	declare -a args=("${HOSTS[@]}")
	declare -a ips
	declare host=''
	declare ip=''
	declare titulo='GR&Aacute;FICOS ESTAT&Iacute;STICOS DE LAT&Ecirc;NCIA DE REDE'

	# Filtrando o vetor $HOSTS para retornar somente os ips
	for ((i = 0; i <= ${#HOSTS[@]}; i++)); do
		((i % 2 == 1)) && ips+=("${HOSTS[$i]}")
	done

	echo 'Criando paginas HTML...'

	# 1o: Criar a pagina index
	cat <<- FIM > ${DIR_WWW}/index.html
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
		"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
		<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
		<head>
		<title>${0##*/}</title>
		<meta http-equiv="content-type" content="text/html;charset=utf-8" />
		<meta name="generator" content="Geany 1.24.1" />
		<meta name="author" content="Sandro Marcell" />
		<style type="text/css">
			* { box-sizing: border-box; }
			html, body { margin:0; padding:0; background:#DDD; color:#333; font: 14px/1.5em Helvetica, Arial, sans-serif; }
			a { text-decoration: none; color: #C33; }
			header, footer, article, nav, section { float: left; padding: 10px; }
			header,footer { width:100%; }
			header, footer { background-color: #333; color: #FFF; text-align: right; height: 100px; }
			header { font-size: 1.8em; font-weight: bold; }
			footer{ background-color: #999; text-align: center; height: 40px; }
			nav { text-align: center; width: 24%; margin-right: 1%; border: 1px solid #CCC; margin:5px; margin-top: 10px; }
			nav a { display: block; width: 100%; background-color: #C33; color: #FFF; height: 30px; margin-bottom: 10px; padding: 10px; border-radius: 3px; line-height: 10px; vertical-align: middle; }
			nav a:hover, nav a:active { background-color: #226; }
			article { width: 75%; height: 1200px; }
			h1 { padding: 0; margin: 0 0 20px 0; text-align: center; }
			p { text-align: center; margin-top: 30px; }
			article section { padding: 0; width: 100%; }
			.container{ width: 1200px; float: left; position: relative; left: 50%; margin-left: -600px; background:#FFF; padding: 10px; }
			.content { width: 100%; height: 100%; overflow: hidden;}
			.hide { display: none; }
		</style>
		<script type="text/javascript">
			function exibirGraficos(id) {
				document.getElementById('objetos').innerHTML = document.getElementById(id).innerHTML;
			}
		</script>
		</head>
		<body>
		<div class="container">
			<nav>
				$(while [ ${#args[@]} -ne 0 ]; do
					host="${args[0]}"
					ip="${args[1]}"
					args=("${args[@]:2}")
					echo "<a href="\"javascript:exibirGraficos\("'$ip'"\)\;\"">$host</a>"
				done)
			</nav>
			<article>
				<h1>GR&Aacute;FICOS ESTAT&Iacute;STICOS DE LAT&Ecirc;NCIA DE REDE</h1>
				<div id="objetos" class="content"><p>&#10229; Clique no menu para visualizar os gr&aacute;ficos.</p></div>
				<section>
					$(for i in "${ips[@]}"; do
						echo "<div id="\"$i\"" class="\"hide\""><object type="\"text/html\"" data="\"${i}.html\"" class="\"content\""></object></div>"
					done)
				</section>
			</article>
			<footer>
				<small>${0##*/} &copy; 2017-$(date '+%Y') <a href="https://github.com/sandromarcell">Sandro Marcell</a></small>
			</footer>
		</div>
	</body>
	</html>
	FIM

	# 2o: Criar pagina especifica para cada host com os periodos definidos
	while [ ${#HOSTS[@]} -ne 0 ]; do
		host="${HOSTS[0]}"
		ip="${HOSTS[1]}"
		HOSTS=("${HOSTS[@]:2}")

		cat <<- FIM > ${DIR_WWW}/${ip}.html
		<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
		"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
		<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
		<head>
		<title>${0##*/}</title>
		<meta http-equiv="content-type" content="text/html;charset=utf-8" />
		<meta name="author" content="Sandro Marcell" />
		<style type="text/css">
		body { margin: 0; padding: 0; background-color: #FFFFFF; width: 100%; height: 100%; font: 20px/1.5em Helvetica, Arial, sans-serif; }
		#header { text-align: center; }
		#content { position: relative; text-align: center; margin: auto; }
		#footer { font-size: 13px; text-align: center; }
		</style>
		<script type="text/javascript">
			var refresh = setTimeout(function() {
				window.location.reload(true);
			}, $((INTERVALO * 1000)));
		</script>
		</head>
		<body>
			<div id="header">
				<p>$host<br /><small>($ip)</small></p>
			</div>
			<div id="content">
				<script type="text/javascript">
					$(for i in $PERIODOS; do
						echo "document.write('<div><img src="\"${ip}-${i}.png?nocache=\' + \(Math.floor\(Math.random\(\) \* 1e20\)\).toString\(36\) + \'\"" alt="\"${0##*/} --html\"" /></div>');"
					done)
				</script>
			</div>
		</body>
		</html>
		FIM
	done
	return 0
}

# Criar os arquivos html se for o caso
# Chamada do script: rtt-graph.sh --html
if [ "$1" == '--html' ]; then
	criarPaginasHTML
	exit 0
fi

# Coletando dados e gerando os graficos
# Chamada do script: rtt-graph.sh
gerarGraficos
