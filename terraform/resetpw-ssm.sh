#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'

usage() {
    cat <<EOF
Usage: terraform/resetpw-ssm.sh [--root|--both] <dev>             <mongodb|prometheus>
       terraform/resetpw-ssm.sh [--root|--both] <uat|prod>        <mongodb>

Rotate SSM-backed credentials on dev, uat, or prod EKS clusters.
Note: prometheus target is dev-only (single shared instance for dev+uat).
Note: prod uses a separate EKS cluster (eks-react-prod) — context auto-set.

Flags (mongodb only):
  --root      Rotate root user only
  --both      Rotate app user, then root user (sequential)
  (default)   Rotate app user only

Targets:
  mongodb     Rotate MongoDB password (default: app user; --root or --both)
  prometheus  Rotate Prometheus basic-auth (dev only — shared dev+uat instance)

Examples:
  terraform/resetpw-ssm.sh dev mongodb            # dev app only (default)
  terraform/resetpw-ssm.sh --root dev mongodb     # dev root only
  terraform/resetpw-ssm.sh --both dev mongodb     # dev app + root sequential
  terraform/resetpw-ssm.sh dev prometheus         # dev prometheus
  terraform/resetpw-ssm.sh uat mongodb            # uat app
  terraform/resetpw-ssm.sh --both prod mongodb    # prod both (auto-uses demo-eks-prod context)

NOTE: Independent from terraform/an-deploy dev-resetpw. Do not run both simultaneously on same env/target (SSM/Mongo race).
EOF
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}ERROR: $1 not installed${NC}" >&2; exit 1
    }
}

# kubectl wrapper carries per-env --context. Only prod overrides (separate EKS cluster).
_k() {
    kubectl ${KUBE_CTX:+"--context" "${KUBE_CTX}"} "$@"
}

assert_no_active_jobs() {
    local ns="$1"
    local active_jobs
    active_jobs="$(_k -n "${ns}" get jobs \
        -o jsonpath='{range .items[?(@.status.active>0)]}{.metadata.name}{" "}{end}' 2>/dev/null | wc -w)"
    [[ "${active_jobs}" -eq 0 ]] || {
        echo -e "${RED}ERROR: ${active_jobs} active Job(s) in ${ns}. Wait or delete manually.${NC}" >&2
        return 1
    }
}

wait_secret_synced() {
    local ns="$1" es_name="$2" timeout_iters="${3:-18}"
    local synced=0
    for _ in $(seq 1 "${timeout_iters}"); do
        if _k -n "${ns}" get externalsecret "${es_name}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
            | grep -q True; then synced=1; break; fi
        sleep 5
    done
    [[ "${synced}" -eq 1 ]] || {
        echo -e "${RED}ERROR: ExternalSecret ${ns}/${es_name} did not reach SecretSynced${NC}" >&2
        return 1
    }
}

reset_mongodb() {
    local env="$1" kind="$2"
    local ns="${env}" cronjob secret field
    case "${kind}" in
        app)  cronjob="rotate-mongo-app-user";  secret="mongo-app-secret";  field="MONGO_APP_PASSWORD" ;;
        root) cronjob="rotate-mongo-root-user"; secret="mongo-root-secret"; field="MONGO_INITDB_ROOT_PASSWORD" ;;
    esac

    echo -e "${BLUE}Rotating MongoDB ${kind} password in ${env} cluster...${NC}"

    _k -n "${ns}" get cronjob "${cronjob}" >/dev/null 2>&1 || {
        echo -e "${RED}ERROR: CronJob ${ns}/${cronjob} not found. Run Terraform secrets module first.${NC}" >&2
        return 1
    }

    # Pre-flight: verify CronJob image was rewritten by kustomize to ECR URL.
    # Raw `kubectl apply -f` on CronJob YAML leaves bare image ref (demo-mongo-rotator:latest)
    # which is not pullable — only kustomize rewrites it to the ECR repository.
    local cronjob_image
    cronjob_image="$(_k -n "${ns}" get cronjob "${cronjob}" \
        -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')"
    if [[ "${cronjob_image}" != *.dkr.ecr.*.amazonaws.com/* ]]; then
        echo -e "${RED}ERROR: CronJob ${ns}/${cronjob} image is '${cronjob_image}' — not an ECR URL.${NC}" >&2
        echo -e "${RED}Image was not rewritten by kustomize. Re-apply via:${NC}" >&2
        echo -e "${YELLOW}  kubectl apply -k k8s-infra-aws-ssm-${env}/${NC}" >&2
        echo -e "${RED}Then re-run this script.${NC}" >&2
        return 1
    fi

    assert_no_active_jobs "${ns}"

    local old_pw
    old_pw="$(_k -n "${ns}" get secret "${secret}" \
        -o jsonpath="{.data.${field}}" | base64 -d 2>/dev/null || true)"

    local job_name="manual-mongo-${kind}-rotatepw-${env}-$(date +%s)"
    _k -n "${ns}" create job "${job_name}" --from="cronjob/${cronjob}" >/dev/null || {
        echo -e "${RED}ERROR: failed to create Job from CronJob${NC}" >&2; return 1
    }
    _k -n "${ns}" wait job/"${job_name}" --for=condition=Complete --timeout=600s || {
        echo -e "${RED}ERROR: Job ${job_name} did not complete within 600s${NC}" >&2
        echo -e "${YELLOW}Cleaning up timed-out job...${NC}" >&2
        _k -n "${ns}" delete job "${job_name}" --ignore-not-found=true >/dev/null 2>&1 || true
        return 1
    }
    _k -n "${ns}" delete job "${job_name}" --ignore-not-found=true >/dev/null 2>&1 || true
    wait_secret_synced "${ns}" "${secret}"

    local new_pw
    new_pw="$(_k -n "${ns}" get secret "${secret}" \
        -o jsonpath="{.data.${field}}" | base64 -d)"
    [[ -n "${new_pw}" && "${new_pw}" != "${old_pw}" ]] || {
        echo -e "${RED}ERROR: MongoDB ${kind} password did not change (still ${#new_pw} chars)${NC}" >&2
        return 1
    }

    if [[ "${kind}" == "app" ]]; then
        echo "  Restarting backend + frontend pods to consume new ${field}"
        _k -n "${ns}" rollout restart deployment/backend deployment/frontend
        _k -n "${ns}" rollout status deployment/backend --timeout=5m
        _k -n "${ns}" rollout status deployment/frontend --timeout=5m
    fi

    echo -e "${CYAN}${ENV_UPPER} MongoDB ${kind} password:${NC} ${new_pw}"
    echo -e "${GREEN}OK${NC} MongoDB ${kind} password rotated in ${env} cluster"
    if [[ "${kind}" == "app" ]]; then
        echo -e "${CYAN}URL:${NC} mongodb://app_user:${new_pw}@${env}-mongo:27017/${env}_be_db"
    else
        echo -e "${CYAN}Verify via:${NC} mongosh --username root --password '${new_pw}' --authenticationDatabase admin"
    fi
}

reset_prometheus() {
    local env="$1"
    local ns="monitor"
    echo -e "${BLUE}Rotating Prometheus basic-auth in ${env} cluster...${NC}"

    # Single shared Prometheus for dev+uat on eks-react-dev-uat cluster.
    # SSM path always uses /demo-eks-dev regardless of env argument.
    local ssm_name="/demo-eks-dev/monitor/prometheus_basic_auth"

    local new_pw
    new_pw="$(openssl rand -base64 36 | tr -d '/+=\n' | cut -c1-32)"

    local hash_line
    if command -v htpasswd >/dev/null 2>&1; then
        hash_line="$(htpasswd -nbBC 10 "" "${new_pw}" | head -1 | sed 's/^://')"
    else
        hash_line="$(python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(rounds=10)).decode())' "${new_pw}")"
    fi
    local ssm_value="admin:${hash_line}"

    aws ssm put-parameter \
        --name "${ssm_name}" \
        --value "${ssm_value}" \
        --type SecureString \
        --overwrite \
        --region us-east-1 >/dev/null || {
        echo -e "${RED}ERROR: aws ssm put-parameter failed for ${ssm_name}${NC}" >&2
        return 1
    }

    local pw_file="/tmp/prometheus-resetpw-${env}-$(date '+%d%b%Y-%Hh%Mm%Ss' | tr 'A-Z' 'a-z').pw"
    printf '%s' "${new_pw}" > "${pw_file}"
    chmod 0600 "${pw_file}"
    find /tmp -maxdepth 1 -name "prometheus-resetpw-*.pw" -not -name "$(basename "${pw_file}")" -delete 2>/dev/null || true

    _k -n "${ns}" annotate externalsecret/prometheus-basic-auth \
        "force-sync=$(date +%s)" --overwrite >/dev/null 2>&1

    local synced=0
    for _ in $(seq 1 30); do
        local current
        current="$(_k -n "${ns}" get secret prometheus-basic-auth \
            -o jsonpath='{.data.auth}' | base64 -d 2>/dev/null || true)"
        if [[ "${current}" == "${ssm_value}" ]]; then synced=1; break; fi
        sleep 1
    done
    [[ "${synced}" -eq 1 ]] || {
        echo -e "${RED}ERROR: K8s Secret did not update within 30s. ES reconcile failed?${NC}" >&2
        echo -e "${YELLOW}Plaintext still in ${pw_file}; SSM updated; pod restart NOT triggered${NC}" >&2
        return 1
    }

    _k -n "${ns}" rollout restart deploy/prometheus >/dev/null 2>&1
    _k -n "${ns}" rollout status deploy/prometheus --timeout=5m >/dev/null 2>&1

    echo ""
    echo -e "  ${GREEN}Password:${NC}  ${new_pw}"
    echo -e "  ${CYAN}File:${NC}      ${pw_file}"
    echo -e "  ${CYAN}SSM:${NC}       ${ssm_name}"
    echo -e "  ${CYAN}Verify:${NC}    curl -sI -u admin:${new_pw} https://prometheus-demo.h0m3.xyz/api/v1/query?query=up"
    echo ""
}

main() {
    local flag="" filtered_args=()
    for arg in "$@"; do
        if [[ -z "${flag}" && ( "${arg}" == --root || "${arg}" == --both ) ]]; then
            flag="${arg}"
        else
            filtered_args+=("${arg}")
        fi
    done
    set -- "${filtered_args[@]}"
    [[ $# -ge 2 ]] || { usage; exit 1; }
    local env="$1" target="$2"; shift 2
    [[ "${env}" == "dev" || "${env}" == "uat" || "${env}" == "prod" ]] || { echo -e "${RED}ERROR: env must be dev, uat, or prod${NC}" >&2; usage; exit 1; }

    readonly ENV_UPPER="$(echo "${env}" | tr '[:lower:]' '[:upper:]')"

    # only prod uses separate EKS cluster. Dev/uat share eks-react-dev-uat (current context).
    local KUBE_CTX=""
    local AWS_ACCOUNT_ID
    AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
    [[ "${env}" == "prod" ]] && KUBE_CTX="arn:aws:eks:us-east-1:${AWS_ACCOUNT_ID}:cluster/eks-react-prod"

    lockfile="/tmp/resetpw-ssm-${env}-${target}.lock"
    if ! mkdir "${lockfile}" 2>/dev/null; then
        echo -e "${RED}ERROR: another resetpw-ssm.sh run on ${env}/${target} in progress (lock: ${lockfile})${NC}" >&2
        echo -e "${RED}NOTE: Do not run both simultaneously on same env/target (SSM/Mongo race).${NC}" >&2
        exit 1
    fi
    trap 'rmdir "${lockfile}" 2>/dev/null || true' EXIT

    case "${target}" in
        mongodb)
            require_cmd kubectl
            case "${flag}" in
                "")      reset_mongodb "${env}" app ;;
                --root)  reset_mongodb "${env}" root ;;
                --both)  reset_mongodb "${env}" app; reset_mongodb "${env}" root ;;
            esac
            ;;
        prometheus)
            [[ "${env}" != "dev" ]] && {
                echo -e "${RED}ERROR: Only dev env supported for prometheus (shared dev+uat instance).${NC}" >&2
                echo -e "${YELLOW}Use: ./resetpw-ssm.sh dev prometheus${NC}" >&2
                exit 1
            }
            [[ -n "${flag}" ]] && echo -e "${YELLOW}WARN: --${flag#--} ignored for prometheus target${NC}"
            require_cmd kubectl
            require_cmd openssl
            require_cmd aws
            command -v htpasswd >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || {
                echo -e "${RED}ERROR: htpasswd or python3 required${NC}" >&2; exit 1
            }
            reset_prometheus "${env}"
            ;;
        *)
            echo -e "${RED}ERROR: target must be mongodb or prometheus${NC}" >&2
            usage; exit 1
            ;;
    esac
}

main "$@"
