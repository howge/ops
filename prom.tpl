{% macro  alert_desc(data) %}


**告警级别**: [{{ data.labels.severity | upper }}] {{ data.annotations.summary }}


**告警应用**: {{ data.labels.project }}::{{ data.labels.app }}


**告警实例**: {{ data.labels.instance }}


**告警描述**: {{ data.annotations.description }}


**告警详情**:
{% for key, value  in  data.labels.items() %}
{% if key != "severity" %}
> {{ key }}: {{ value}}
{% endif %}
{%- endfor -%}
{%- endmacro -%}

{% macro loop_alerts(list) %}
**告警时间**: {{ now }}
{%- for data in list -%}
    {{ alert_desc(data) }}
{%- endfor -%}
{%- endmacro -%}

{% if alerts | length  >0 %}
[PROBLEM:{{ alerts | length }}] **{{ alertname }}**


**Alerts Firing**
{{ loop_alerts(alerts)}}
{%- endif -%}
{% if resolveds | length  >0 %}
[RECOVERY:{{ resolveds | length }}] **{{ alertname }}**


**Alerts Resolved**
{{ loop_alerts(resolveds)}}
{%- endif -%}
