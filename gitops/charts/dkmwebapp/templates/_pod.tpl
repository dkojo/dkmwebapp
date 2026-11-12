{{- define "dkmwebapp.podTemplate" -}}
metadata:
  labels:
    app: dkmwebapp
spec:
  terminationGracePeriodSeconds: 30
  securityContext:
    runAsNonRoot: true
    seccompProfile: { type: RuntimeDefault }
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector: { matchLabels: { app: dkmwebapp } }
  containers:
    - name: dkmwebapp
      image: "{{ .Values.image.repository }}@{{ required "image.digest is set by CI" .Values.image.digest }}"
      ports:
        - { name: http, containerPort: 8080 }
      env:
        - { name: APP_VERSION, value: {{ .Values.image.version | quote }} }
        - { name: FAULT_ERROR_RATE, value: {{ .Values.faultErrorRate | quote }} }
        - name: NODE_IP
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - { name: JAVA_TOOL_OPTIONS, value: "-javaagent:/app/otel.jar" }
        - { name: OTEL_SERVICE_NAME, value: dkmwebapp }
        - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://$(NODE_IP):4318" }   # this node's collector
        - { name: OTEL_EXPORTER_OTLP_PROTOCOL, value: http/protobuf }
        - { name: OTEL_TRACES_EXPORTER, value: otlp }
        - { name: OTEL_METRICS_EXPORTER, value: none }   # metrics come from Micrometer → Prometheus
        - { name: OTEL_LOGS_EXPORTER, value: none }      # logs come from the collector reading pod logs
        - { name: OTEL_RESOURCE_ATTRIBUTES, value: "service.version={{ .Values.image.version }}" }
      envFrom:
        - secretRef: { name: dkm-db }       # DB_HOST, DB_PORT, DB_NAME, DB_USERNAME, DB_PASSWORD
      resources: {{- toYaml .Values.resources | nindent 8 }}
      lifecycle:
        # Keep serving while the ALB deregisters this pod. Without it, the ALB keeps sending requests for a few
        # seconds to a pod that is already shutting down (measured: 2 failed requests per rolling update).
        # The native sleep action needs no shell, which the distroless image doesn't have.
        preStop:
          sleep: { seconds: 15 }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      startupProbe:
        httpGet: { path: /actuator/health/liveness, port: http }
        periodSeconds: 5
        failureThreshold: 30                 # up to 150 s for the JVM to start
      livenessProbe:
        httpGet: { path: /actuator/health/liveness, port: http }
        periodSeconds: 10
      readinessProbe:
        httpGet: { path: /actuator/health/readiness, port: http }
        periodSeconds: 5
      volumeMounts:
        - { name: tmp, mountPath: /tmp }     # Spring Boot needs a writable /tmp; the rest is read-only
  volumes:
    - name: tmp
      emptyDir: {}
{{- end }}
