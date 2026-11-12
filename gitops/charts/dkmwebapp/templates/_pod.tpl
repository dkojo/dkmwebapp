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
      envFrom:
        - secretRef: { name: dkm-db }       # DB_HOST, DB_PORT, DB_NAME, DB_USERNAME, DB_PASSWORD
      resources: {{- toYaml .Values.resources | nindent 8 }}
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
