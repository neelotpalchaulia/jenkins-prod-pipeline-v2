pipeline {
  agent any

  options {
    disableConcurrentBuilds()
    timestamps()
    ansiColor('xterm')
    buildDiscarder(logRotator(numToKeepStr: '30'))
    timeout(time: 30, unit: 'MINUTES')
  }

  parameters {
    string(name: 'BRANCH', defaultValue: 'main', description: 'Git branch to build')
    choice(name: 'DEPLOY_TO', choices: ['staging-only', 'prod'], description: 'Where to deploy')
    string(name: 'DEPLOY_IP', defaultValue: '4.206.144.122', description: 'Public Deploy VM IP')
    string(name: 'ACR', defaultValue: 'acrjenkinsxyz.azurecr.io', description: 'Azure Container Registry login server')
    string(name: 'APP', defaultValue: 'myapp', description: 'App / image name')
    booleanParam(name: 'RUN_SONAR', defaultValue: true, description: 'Run SonarQube analysis + Quality Gate')
  }

  environment {
    IMAGE_SHA    = "${params.ACR}/${params.APP}:${env.GIT_COMMIT?.take(8)}"
    IMAGE_LATEST = "${params.ACR}/${params.APP}:latest"
    STAGING_PORT = '8081'
    PROD_PORT    = '8080'
  }

  triggers { pollSCM('@daily') } // add GitHub webhook for instant triggers

  stages {

    stage('Checkout') {
      steps {
        checkout([$class: 'GitSCM',
          branches: [[name: "${params.BRANCH}"]],
          userRemoteConfigs: [[url: scm.userRemoteConfigs[0].url]]
        ])
      }
    }

    stage('Go fmt & Unit Tests') {
      steps {
        sh '''
          /usr/local/go/bin/go fmt ./app/... | tee fmt.out
          /usr/local/go/bin/go -C app test ./... -v | tee test.out
        '''
      }
      post { always { archiveArtifacts artifacts: 'fmt.out,test.out', onlyIfSuccessful: false } }
    }

    stage('Static Analysis (SonarQube)') {
      when { expression { return params.RUN_SONAR } }
      steps {
        withSonarQubeEnv('sonar-local') {
          sh """
            sonar-scanner \
              -Dsonar.projectKey=${params.APP} \
              -Dsonar.sources=app \
              -Dsonar.tests=app
          """
        }
      }
    }

    stage('Quality Gate') {
      when { expression { return params.RUN_SONAR } }
      steps {
        timeout(time: 5, unit: 'MINUTES') {
          waitForQualityGate abortPipeline: true
        }
      }
    }

    stage('Build Docker image') {
      steps {
        sh "docker build -t ${IMAGE_SHA} -t ${IMAGE_LATEST} ."
      }
    }

    stage('Security scan (Trivy)') {
      steps {
        sh "trivy image --exit-code 1 --severity HIGH,CRITICAL ${IMAGE_SHA} | tee trivy.out"
      }
      post { always { archiveArtifacts artifacts: 'trivy.out', onlyIfSuccessful: false } }
    }

    stage('Push to ACR') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds',
                  usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sh '''
            echo "$ACR_PASS" | docker login ${ACR} -u "$ACR_USER" --password-stdin
          '''
        }
        sh """
          docker push ${IMAGE_SHA}
          docker push ${IMAGE_LATEST}
        """
      }
    }

    stage('Deploy to STAGING (remote)') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds',
                  usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sshagent(credentials: ['deploy-ssh']) {
            sh """
              ssh -o StrictHostKeyChecking=no azureuser@${params.DEPLOY_IP} "
                docker login ${params.ACR} -u ${ACR_USER} -p ${ACR_PASS} >/dev/null 2>&1 || true;
                docker pull ${IMAGE_SHA};
                docker rm -f ${params.APP}-staging || true;
                docker run -d --name ${params.APP}-staging -p ${STAGING_PORT}:8080 ${IMAGE_SHA}
              "
            """
          }
        }
      }
    }

    stage('Health check (staging)') {
      steps {
        sh "scripts/health_check.sh http://${params.DEPLOY_IP}:${STAGING_PORT}/health"
      }
    }

    stage('Approval for PROD') {
      when {
        allOf {
          expression { params.DEPLOY_TO == 'prod' }
          branch 'main'
        }
      }
      steps {
        input message: 'Promote to PRODUCTION?', ok: 'Deploy'
      }
    }

    stage('Deploy to PROD (with rollback)') {
      when {
        allOf {
          expression { params.DEPLOY_TO == 'prod' }
          branch 'main'
        }
      }
      steps {
        withCredentials([usernamePassword(credentialsId: 'acr-creds',
                  usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
          sshagent(credentials: ['deploy-ssh']) {
            sh """
              ssh -o StrictHostKeyChecking=no azureuser@${params.DEPLOY_IP} "
                set -e
                prev=\$(docker inspect -f '{{.Config.Image}}' ${params.APP}-prod 2>/dev/null || true)
                docker login ${params.ACR} -u ${ACR_USER} -p ${ACR_PASS} >/dev/null 2>&1 || true
                docker pull ${IMAGE_SHA}
                docker rm -f ${params.APP}-prod || true
                docker run -d --name ${params.APP}-prod -p ${PROD_PORT}:8080 ${IMAGE_SHA}
                for i in {1..30}; do curl -fsS http://localhost:${PROD_PORT}/health && ok=1 && break || true; sleep 3; done
                if [ "\$ok" != "1" ]; then
                  echo 'Prod health failed. Rolling back…'
                  if [ -n "\$prev" ]; then
                    docker rm -f ${params.APP}-prod || true
                    docker run -d --name ${params.APP}-prod -p ${PROD_PORT}:8080 "\$prev"
                  fi
                  exit 1
                fi
              "
            """
          }
        }
      }
    }
  }

  post {
    success { echo '✅ Pipeline succeeded' }
    failure { echo '❌ Pipeline failed' }
  }
}
