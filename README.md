# TestMustage
DevOps Тестове Завдання
клас! вітаю — у тебе вже все працює: образ збирається, CI/CD проходить, деплой в Kubernetes валиться зелено, `/redis` дає `{"status":true}` і навіть домен відкривається. Нижче даю **готовий README** (можеш вставити в `README.md` без змін) + коротке пояснення “чому так” і що саме відбувається під капотом.

---

# NestJS + Redis → CI/CD → Kubernetes

Маленький сервіс на NestJS з ендпоінтом `/redis`, який перевіряє підключення до Redis і повертає `{"status": true/false}`.
Побудовано **повний цикл**: Docker → Docker Hub → GitHub Actions → (Self-Hosted Runner) → Kubernetes (Deployment, Service, Ingress, Secrets).

## Швидкий старт

### Через CI/CD 

1. **Prerequisites**

   * Kubernetes локально (Docker Desktop або Minikube).
   * NGINX Ingress увімкнений.
   * Docker Hub акаунт.

2. **Secrets у GitHub (Settings → Secrets → Actions)**

   * `DOCKERHUB_USERNAME` — твій логін Docker Hub.
   * `DOCKERHUB_TOKEN` — Docker Hub Access Token.
   * `REDIS_PASSWORD` — пароль для Redis.
   * (якщо кластер локальний) **Self-Hosted Runner** → див. розділ “Self-Hosted Runner”.
     Для локального кластера `KUBE_CONFIG` **не потрібен** — раннер використовує локальний `~/.kube/config`.

3. **k8s/ingress.yaml → домен**

   * Host: `domain.tld` (можеш змінити на свій).
   * Додай запис у `hosts`:

     * **Linux/macOS**:
       `echo "<IP-кластера> domain.tld" | sudo tee -a /etc/hosts`
     * **Windows**:
       відкрити `C:\Windows\System32\drivers\etc\hosts` як адміністратор і додати рядок
       `<IP-кластера>  domain.tld`
   * IP для:

     * **Minikube**: `minikube ip`
     * **Docker Desktop K8s**: часто `127.0.0.1` (Ingress LB прокинений локально).

4. **Пуш коду у main**

   * GitHub Actions виконає:

     * **build_and_push** → зібрати Docker-образ → пушнути `:latest` і `:<commit-sha>`;
     * **deploy** (на self-hosted runner) → оновити Kubernetes маніфести та дочекатися `rollout`.

5. **Перевірка**

   ```bash
   kubectl get pods,svc,ingress
   curl http://domain.tld/redis
   # -> {"status":true,"message":"Redis connection is healthy"}
   ```

---

###Ручний запуск для швидкої перевірки

```bash
# 1) Локальний Docker Image
docker build -t katerinadud/nestjs-app:least .
docker run --rm -p 3000:3000 \
  -e REDIS_HOST=host.docker.internal -e REDIS_PORT=6379 -e REDIS_PASSWORD=changeme \
  katerinadud/nestjs-app:dev

# 2) Kubernetes (якщо Redis в кластері)
kubectl apply -f k8s/redis-secret.yaml
kubectl apply -f k8s/redis-deployment.yaml
kubectl apply -f k8s/nestjs-deployment.yaml
kubectl apply -f k8s/ingress.yaml
kubectl rollout status deploy/nestjs-app
```

---

## Що саме відбувається при деплої 

```
git push → GitHub Actions:
  1) build_and_push (ubuntu runner)
     - docker build (багатоетапний Dockerfile)
     - push в Docker Hub: katerinadud/nestjs-app:latest та :<git-sha>

  2) deploy (self-hosted runner — твій ПК)
     - оновлює redis-secret у кластері з $REDIS_PASSWORD
     - kustomize set image nestjs-app → :<git-sha>
     - kubectl apply -k k8s
     - kubectl rollout status
```

У кластері створюються:

* `Deployment redis` + `Service redis` (порт 6379)
* `Deployment nestjs-app` + `Service nestjs-app` (порт 3000 → 80)
* `Ingress` з host `domain.tld`
* `Secret redis-secret` з ключем `REDIS_PASSWORD`

---

## Архітектурна міні схема 

```
               ┌──────────────────────────┐
git push ─────▶│  GitHub Actions (build)  │
               │  docker build & push     │
               └──────────┬───────────────┘
                          │  image: katerinadud/nestjs-app:<sha>
                          ▼
               ┌──────────────────────────┐
               │ Self-Hosted Runner (deploy)
               │ kustomize + kubectl apply│
               └──────────┬───────────────┘
                          ▼
┌───────────────────────────────────────────────────────────┐
│                       Kubernetes                          │
│  ┌────────────┐     ┌────────────────┐     ┌───────────┐  │
│  │ Secret     │     │ Deployment     │     │ Deployment│  │
│  │ redis-pass │────▶│ redis          │◀────│ nestjs    │  │
│  └────────────┘     │ Service:6379   │     │ Service:80│  │
│        ▲            └────────────────┘     └───────────┘  │
│        │                          ▲               │        │
│        └──────── env REDIS_PASSWORD│               │        │
│                                   │         Ingress: domain.tld
└───────────────────────────────────────────────────────────┘
```

---

## Структура репозиторію

```
.
├── src/                 # NestJS код (порт 3000, /redis)
├── Dockerfile           # multi-stage, non-root, healthcheck
├── .dockerignore
├── k8s/
│   ├── redis-secret.yaml       # Secret: REDIS_PASSWORD
│   ├── redis-deployment.yaml   # Redis Deployment+Service
│   ├── nestjs-deployment.yaml  # App Deployment+Service (PORT=3000)
│   ├── ingress.yaml            # NGINX Ingress (domain.tld)
│   └── kustomization.yaml      # images: katerinadud/nestjs-app
└── .github/workflows/ci-cd.yml  # build → push → deploy
```

---

## Деталі реалізації

### Dockerfile 

* **Multi-stage**:

  * `deps` — ставимо **всі** залежності (`npm ci`) → є `tsc/nest`.
  * `build` — `npm run build` → отримуємо `dist/`.
  * `prod` — `npm ci --omit=dev` + копія `dist/` → **малий**, **без dev-deps**.
* **Безпека**: `USER appuser`, без root.
* **Healthcheck**: GET `http://127.0.0.1:3000/redis`.

### Kubernetes

* **Секрети**: `redis-secret` з ключем `REDIS_PASSWORD`. Використовується і Redis’ом (`--requirepass`), і додатком (ENV).
* **Приведений порт**: усе на **3000** (код, containerPort, targetPort, probes).
* **Проби**:

  * `readinessProbe`: `/redis` — сервіс готовий, коли є конект до Redis.
  * `livenessProbe`: `/` — живість процесу.
* **Ingress**: DNS-host → `domain.tld`.
  Для локалки мапимо IP кластера у файл hosts; для продакшна — A-record на публічний IP Ingress Controller’а.
* **Kustomize**: зручно **підміняти тег образу** на `${{ github.sha }}` — отримуємо immutable деплой.

### CI/CD

* **build_and_push**:

  * логін у Docker Hub (secrets),
  * `docker/build-push-action` → теги `:latest` і `:<sha>`.
* **deploy**:

  * **self-hosted runner** (бо локальний кластер недоступний із хмари),
  * створює/оновлює `redis-secret` з GitHub Secret,
  * `kustomize edit set image katerinadud/nestjs-app=<repo>:<sha>`,
  * `kubectl apply -k k8s` і `rollout status`.

---

## Self-Hosted Runner 

**Чому:** GitHub хмарний раннер не бачить локальний кластер (`kubernetes.docker.internal` / `127.0.0.1`). Тому деплой виконуємо **на ПК для тесту**, який має доступ до кластера.



### Linux/WSL make Runner

```bash
mkdir -p ~/actions-runner && cd ~/actions-runner
VER=2.328.0
curl -L -o actions-runner.tar.gz https://github.com/actions/runner/releases/download/v$VER/actions-runner-linux-x64-$VER.tar.gz
tar xzf actions-runner.tar.gz
./config.sh --url https://github.com/<user>/<repo> --token <TOKEN>
./run.sh
# (опційно) як сервіс – див. офіційну інструкцію runner’а
```

> На self-hosted runner встанови `kubectl` і `kustomize` (наприклад, через Chocolatey на Windows або apt на Linux).

---

## DNS / Домени

### Локальна розробка

* **Minikube**: `minikube addons enable ingress`, далі:

  ```bash
  echo "$(minikube ip) domain.tld" | sudo tee -a /etc/hosts
  ```
* **Docker Desktop K8s**:

  * Зазвичай Ingress слухає `127.0.0.1`.
  * У `hosts` `127.0.0.1  domain.tld`.

### Публічний домен (хмара)

* Створити A-record для `domain.tld` → на **External IP** Ingress Controller’а (наприклад, LoadBalancer IP).
* У `ingress.yaml` вказати цей host. Після застосування `curl http(s)://domain.tld/redis`.

---

## Як це все перевірити (cheat-sheet)

```bash
# Образ, що реально використовується:
kubectl get deploy nestjs-app -o jsonpath='{.spec.template.spec.containers[0].image}'; echo

# Статус роллаута:
kubectl rollout status deploy/nestjs-app --timeout=300s

# Логи:
kubectl logs deploy/nestjs-app --tail=100
kubectl logs deploy/redis --tail=60

# Події (останнє зверху):
kubectl get events --sort-by=.lastTimestamp | tail -n 40

# Перевірка Redis з пода:
POD=$(kubectl get pod -l app=nestjs-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -- sh -lc 'apk add --no-cache redis >/dev/null 2>&1 || true; redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASSWORD ping'
```

---

## Типові помилки та швидкі фікси

* **`ImagePullBackOff`** — невірний тег/нема доступу до Docker Hub.
  Переконайся, що деплоїш `:<commit-sha>` (kustomize set image) і token валідний.
* **`Readiness probe failed /redis`** — Redis не готовий/не той пароль.
  Додай **initContainer** wait-redis (див. нижче) і звір пароль у Secret.
* **Хмарний раннер не бачить локальний кластер** — став **self-hosted runner**.


---

## Чому саме такий підхід

* **Multi-stage Dockerfile**: збірка з dev-deps, але прод-образ без них → менший розмір і менша поверхня атаки.
* **Non-root user** у контейнері: базова безпека.
* **Kustomize**: просте підміщення тегів образів на **immutable** `:<commit-sha>` → гарантований rollout, без гри з `latest`/кешами.
* **Readiness через `/redis`**: застосунок вважається “готовим”, тільки коли Redis дійсно доступний.
* **Secrets**: пароль Redis у `Secret`, а не в маніфестах/іміджі.
* **Self-Hosted Runner**: необхідний, якщо кластер локальний (GitHub хмарний раннер не бачить `127.0.0.1`/`kubernetes.docker.internal`).

---

## (Місце для скріншотів / демо)

* <img width="825" height="209" alt="image" src="https://github.com/user-attachments/assets/974a4b33-840a-465c-9193-d203e61e541a" />
 GitHub Actions: `build_and_push` / `deploy` — успішні.

* <img width="1490" height="285" alt="image" src="https://github.com/user-attachments/assets/1f41574d-6f77-4f86-9e89-10551dc41a42" />
* ✅ `kubectl get pods,svc,ingress` — усі ресурси є, pod’и Ready.
*
* <img width="806" height="189" alt="image" src="https://github.com/user-attachments/assets/82090f0b-482d-4193-abe5-86a84161b227" />
* ✅ Браузер: `http://domain.tld/redis` → `{"status":true,...}`.

<img width="1404" height="189" alt="image" src="https://github.com/user-attachments/assets/f4f96597-e6ed-4a80-9178-3b362e90307b" />
* ✅ Docker Images in use.

---

## Висновок

Ця тестова задача була для мене дуже корисною

Я дякую компанії **Mustage** за надану можливість виконати це тестове завдання — воно допомогло мені поглибити знання DevOps-практик.






