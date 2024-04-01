docker build .. -f ./Dockerfile-core -t kopilov/jetlend_ru_dashboard:core-1.1
docker build .. -f ./Dockerfile-jupyter -t kopilov/jetlend_ru_dashboard:jupyter-1.1

#docker push kopilov/jetlend_ru_dashboard:core-1.1
#docker push kopilov/jetlend_ru_dashboard:jupyter-1.1
